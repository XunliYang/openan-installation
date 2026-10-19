#!/usr/bin/env python3
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""Guided evaluation configuration; secrets only in memory and kubectl stdin.

Simplified wizard: components → DB password → LLM (once, reuse for both)
→ admin password → hostname. Everything else defaults to evaluation mode
(in-cluster PostgreSQL, auto signing, generated models.yaml).

Production/custom HTTPS profiles use reviewed values (see example.values.yaml)
and existing Secrets instead. No defaults for passwords, no credential
arguments, no Secret overwrite.
"""
import argparse
import base64
import getpass
import hashlib
import hmac
import json
from pathlib import Path
import re
import secrets
import subprocess
import urllib.error
import urllib.request

COMPONENTS = ("registry", "orchestration")


def _kubectl_json(args, stdin=None):
    return subprocess.run(["kubectl", *args], input=stdin, capture_output=True, text=True)


def create_secret(namespace, name, values):
    result = _kubectl_json(["get", "secret", name, "-n", namespace, "--ignore-not-found", "-o", "name"])
    if result.returncode or result.stdout.strip():
        raise RuntimeError("Secret lookup failed or a Secret already exists; use reviewed values for upgrades")
    document = {"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
                "metadata": {"namespace": namespace, "name": name},
                "data": {key: base64.b64encode(value.encode()).decode() for key, value in values.items()}}
    result = _kubectl_json(["create", "-f", "-"], stdin=json.dumps(document))
    if result.returncode:
        # Kubernetes error output can include submitted objects; never echo it.
        raise RuntimeError("Secret creation failed; inspect Kubernetes audit/status without exposing credentials")


def create_configmap(namespace, name, data):
    result = _kubectl_json(["get", "configmap", name, "-n", namespace, "--ignore-not-found", "-o", "name"])
    if result.returncode or result.stdout.strip():
        raise RuntimeError("ConfigMap lookup failed or a ConfigMap already exists; use existing references for upgrades")
    document = {"apiVersion": "v1", "kind": "ConfigMap",
                "metadata": {"namespace": namespace, "name": name},
                "data": data}
    result = _kubectl_json(["create", "-f", "-"], stdin=json.dumps(document))
    if result.returncode:
        raise RuntimeError("ConfigMap creation failed; inspect Kubernetes status without exposing credentials")


def ask(label):
    value = input(label + ": ").strip()
    if not value:
        raise ValueError("Every requested non-secret field is required")
    return value


def choose(label, options, default):
    value = input(f"{label} [{'/'.join(options)}, default: {default}]: ").strip().lower() or default
    if value not in options:
        raise ValueError(f"Unsupported {label}: {value}")
    return value


def secret_input(label):
    # getpass warns and falls back to echo if no TTY; refuse that unsafe fallback.
    import sys
    if not sys.stdin.isatty():
        raise ValueError("Interactive secrets require a terminal; use --values with existing Secrets in CI")
    value = getpass.getpass(label + ": ")
    if not value:
        raise ValueError("Empty secrets are not allowed")
    return value


def probe_llm(model, url, api_key):
    """Best-effort connectivity probe; never includes the key in any message."""
    payload = json.dumps({"model": model, "messages": [{"role": "user", "content": "ping"}],
                          "max_tokens": 1}).encode()
    request = urllib.request.Request(url, data=payload, method="POST",
                                     headers={"Content-Type": "application/json",
                                              "Authorization": "Bearer " + api_key})
    try:
        with urllib.request.urlopen(request, timeout=8) as response:
            if response.status == 200:
                print("  LLM endpoint reachable")
                return True
            print(f"  LLM endpoint answered HTTP {response.status}")
            return False
    except urllib.error.HTTPError as error:
        print(f"  LLM endpoint answered HTTP {error.code} (check model id and API key)")
        return False
    except (urllib.error.URLError, OSError, TimeoutError) as error:
        print(f"  LLM endpoint unreachable: {error}")
        return False


def models_yaml(model, url):
    """chat-only models.yaml; the API key is referenced by env name, never inlined."""
    return ("models:\n"
            "  chat:\n"
            "    provider: openai_compatible\n"
            f"    model: {json.dumps(model)}\n"
            f"    url: {json.dumps(url)}\n"
            "    api_key_env: LLM_CHAT_API_KEY\n")


def collect_llm(component):
    for _ in range(3):
        model = ask(f"{component} chat model id")
        url = ask(f"{component} chat URL (e.g. https://api.example.com/v1/chat/completions)")
        api_key = secret_input(f"{component} chat API key")
        if probe_llm(model, url, api_key):
            return model, url, api_key
        if input("  Continue anyway? [y/N]: ").strip().lower() == "y":
            return model, url, api_key
    raise ValueError(f"LLM configuration for {component} abandoned after 3 attempts")


def choose_components():
    selection = choose("components", ["all", "registry", "orchestration"], "all")
    if selection == "all":
        return {"registry": True, "orchestration": True}
    if selection == "registry":
        return {"registry": True, "orchestration": False}
    return {"registry": False, "orchestration": True}


def configure(namespace, release, output, tag=None):
    if not output.parent.is_dir():
        raise ValueError("Output parent directory must already exist")
    if output.exists():
        raise ValueError("Output exists; refusing to overwrite deployment configuration")

    print()
    print("  Press Enter to accept the [default] for each prompt.")
    print()

    # --- 1. Components -------------------------------------------------------
    components = choose_components()
    enabled = [component for component in COMPONENTS if components[component]]
    if not tag:
        tag = ask("Compatible application image tag (already pushed)")
    prefix = release + "-"

    # --- 2. Database (in-cluster default, just one password) ---------------
    db_mode = choose("SQL hosting", ["in-cluster", "external"], "in-cluster")
    external_db = {}
    names = users = {}
    if db_mode == "external":
        db_type = ask("External SQL type: mysql or postgresql")
        if db_type not in {"mysql", "postgresql"}:
            raise ValueError("Unsupported SQL type")
        host = ask("External SQL host")
        port = int(ask("External SQL port"))
        if not 1 <= port <= 65535:
            raise ValueError("SQL port must be 1..65535")
        names = {component: ask(component + " database name") for component in enabled}
        if len(names) > 1 and names["registry"] == names["orchestration"]:
            raise ValueError("Use separate database names")
        users = {component: ask(component + " database username") for component in enabled}
        external_db = {"type": db_type, "host": host, "port": port}

    # --- 3. LLM (ask once, offer to reuse) ---------------------------------
    llm = {}
    models_mode = choose("models.yaml source", ["generate", "existing"], "generate")
    models_ref = {}
    if models_mode == "existing":
        models_ref = {component: ask(component + " existing models.yaml ConfigMap") for component in enabled}
    elif enabled:
        # Ask for the first component, then offer to reuse
        first = enabled[0]
        llm[first] = collect_llm(first)
        for other in enabled[1:]:
            reuse = choose(f"use same LLM for {other}", ["yes", "no"], "yes")
            if reuse == "no":
                llm[other] = collect_llm(other)
            else:
                llm[other] = llm[first]

    # --- 4. Signing (auto default, one question) ----------------------------
    signing_ref = None
    if components["registry"]:
        if choose("registry signing material", ["auto", "secret"], "auto") == "secret":
            signing_ref = ask("Existing registry signing Secret (sign.cer, sign_key.pem, cert_pwd)")

    agent_registry_url = None
    if components["orchestration"] and not components["registry"]:
        agent_registry_url = ask("External agent registry URL for orchestration (http(s)://...)")
        if not re.match(r"^https?://", agent_registry_url):
            raise ValueError("Agent registry URL must start with http:// or https://")

    ingress_host = ask("Public HTTP evaluation hostname (empty = IP access)")

    # Check public references before collecting/creating any credentials.
    checks = [("configmap", name) for name in models_ref.values()]
    if signing_ref:
        checks.append(("secret", signing_ref))
    for kind, name in checks:
        result = _kubectl_json(["get", kind, name, "-n", namespace, "-o", "name"])
        if result.returncode:
            raise ValueError(f"Required model/signing reference is missing or inaccessible: {name}")

    # --- 5. Secrets collection ----------------------------------------------
    print()
    print("  Setting up secrets (input is hidden)...")
    print()

    in_cluster_password = None
    if db_mode == "in-cluster":
        in_cluster_password = secret_input("PostgreSQL password (shared by the seeded app users)")
        if len(in_cluster_password) < 8:
            raise ValueError("PostgreSQL password requires at least 8 characters")

    sql_passwords = {}
    if db_mode == "external":
        sql_passwords = {component: secret_input(component + " SQL password") for component in enabled}

    admin = None
    if components["orchestration"]:
        admin = secret_input("Initial admin password (change it in the web UI before API use)")
        if len(admin) < 8 or not all(re.search(p, admin) for p in (r"[a-z]", r"[A-Z]", r"[0-9]", r"[^a-zA-Z0-9]")):
            raise ValueError("Initial password requires 8+ characters and lower/upper/digit/special classes")

    # --- Service-token machinery (registry <-> orchestration pairing) ---------
    token = hmac_key = fingerprint = credential = None
    if components["registry"]:
        token, hmac_key, fingerprint = (secrets.token_urlsafe(48) for _ in range(3))
        credential = ("credential.orchestration.identity=orchestration-service\n"
                      "credential.orchestration.role=partner_service\n"
                      "credential.orchestration.enabled=true\ncredential.orchestration.token_hash="
                      + hmac.new(hmac_key.encode(), token.encode(), hashlib.sha256).hexdigest() + "\n")

    # Namespace creation is idempotent and carries no secret material.
    ns = subprocess.run(["kubectl", "create", "namespace", namespace, "--dry-run=client", "-o", "json"],
                        capture_output=True, text=True, check=True)
    subprocess.run(["kubectl", "apply", "-f", "-"], input=ns.stdout, text=True, check=True)

    # --- Create Secrets / ConfigMaps -----------------------------------------
    if in_cluster_password is not None:
        create_secret(namespace, prefix + "pg", {"postgres-password": in_cluster_password})
    for component, password in sql_passwords.items():
        create_secret(namespace, prefix + ("rc-db" if component == "registry" else "oc-db"),
                      {"db-password": password})
    if models_mode == "generate":
        for component in enabled:
            model, url, _ = llm[component]
            name = prefix + ("rc-models" if component == "registry" else "oc-models")
            create_configmap(namespace, name, {"models.yaml": models_yaml(model, url)})
            models_ref[component] = name

    rc_runtime = {"INTEGRATION_TOKEN_HMAC_KEY": hmac_key, "INTEGRATION_FINGERPRINT_KEY": fingerprint} \
        if components["registry"] else None
    if rc_runtime is not None and models_mode == "generate" and components["registry"]:
        rc_runtime["LLM_CHAT_API_KEY"] = llm["registry"][2]
    oc_runtime = {}
    if admin is not None:
        oc_runtime["OC_ADMIN_INITIAL_PASSWORD"] = admin
        if components["registry"]:
            oc_runtime["REGISTRY_ACCESS_TOKEN"] = token
        if models_mode == "generate" and components["orchestration"]:
            oc_runtime["LLM_CHAT_API_KEY"] = llm["orchestration"][2]
    if rc_runtime is not None:
        create_secret(namespace, prefix + "rc-runtime", rc_runtime)
        create_secret(namespace, prefix + "rc-credentials", {"integration_credentials.conf": credential})
    if oc_runtime:
        create_secret(namespace, prefix + "oc-runtime", oc_runtime)

    # --- Assemble non-secret values -------------------------------------------
    values = {"namespace": namespace, "frontend": {"image": {"tag": tag}}}
    if db_mode == "in-cluster":
        values["postgresql"] = {"enabled": True, "existingSecret": prefix + "pg"}
        values["database"] = {"type": "postgresql"}
    else:
        values["postgresql"] = {"enabled": False}
        values["database"] = dict(external_db)
        for component in enabled:
            values["database"][component] = {
                "name": names[component], "username": users[component],
                "existingSecret": prefix + ("rc-db" if component == "registry" else "oc-db")}
    if components["registry"]:
        values["registry"] = {"runtimeSecret": prefix + "rc-runtime",
                              "credentialSecret": prefix + "rc-credentials",
                              "modelsConfigMap": models_ref["registry"], "image": {"tag": tag}}
        if signing_ref:
            values["registry"]["signing"] = {"mode": "secret", "existingSecret": signing_ref}
        else:
            values["registry"]["signing"] = {"mode": "auto"}
    else:
        values["registry"] = {"enabled": False}
    if components["orchestration"]:
        values["orchestration"] = {"runtimeSecret": prefix + "oc-runtime",
                                   "modelsConfigMap": models_ref["orchestration"], "image": {"tag": tag}}
        if agent_registry_url:
            values["orchestration"]["agentRegistryUrl"] = agent_registry_url
    else:
        values["orchestration"] = {"enabled": False}
        values["frontend"] = {"enabled": False, "image": {"tag": tag}}
    values["ingress"] = {"host": ingress_host}

    # Only non-secret JSON/YAML-compatible values. Exclusive creation preserves operator files.
    with output.open("x", encoding="utf-8") as stream:
        json.dump(values, stream, indent=2)
    print("Non-secret values created. Secrets are stored only in Kubernetes. Use reviewed HTTPS values for production.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--namespace", required=True)
    parser.add_argument("--release", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--tag", help="Application image tag; skips the interactive tag question")
    args = parser.parse_args()
    for name in (args.namespace, args.release):
        if not re.fullmatch(r"[a-z0-9](?:[-a-z0-9]*[a-z0-9])?", name) or len(name) > 53:
            parser.error("Invalid namespace/release")
    try:
        configure(args.namespace, args.release, args.output, tag=args.tag)
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError):
        parser.exit(2, "Configuration failed without exposing secret values; existing Secrets are not overwritten.\n")
