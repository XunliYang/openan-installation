#!/usr/bin/env python3
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""Guided evaluation configuration; secrets only in memory and kubectl stdin.

Simplified wizard: components → image tags (shared or per-component) → LLM
(once, reuse for both) → signing → admin password. Everything else is
automatic evaluation mode: in-cluster PostgreSQL, storage on the cluster's
default StorageClass (automatic node-pinned local hostPath fallback when none
exists), auto signing, generated models.yaml, and the empty catch-all Ingress
host for direct LB-IP access.

Production profiles (external SQL, HTTPS, host-based routing) use reviewed
values (see example.values.yaml) and existing Secrets instead. No defaults
for passwords, no credential arguments, no Secret overwrite.
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
    if result.returncode:
        raise RuntimeError(f"Could not check Secret '{name}' in namespace '{namespace}'; verify kubeconfig and RBAC")
    if result.stdout.strip():
        raise RuntimeError(f"Secret '{name}' already exists; use reviewed values for upgrades instead of overwriting")
    document = {"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
                "metadata": {"namespace": namespace, "name": name},
                "data": {key: base64.b64encode(value.encode()).decode() for key, value in values.items()}}
    result = _kubectl_json(["create", "-f", "-"], stdin=json.dumps(document))
    if result.returncode:
        # Kubernetes error output can include submitted objects; never echo it.
        raise RuntimeError(f"Creating Secret '{name}' failed; inspect Kubernetes status without exposing credentials")


def create_configmap(namespace, name, data):
    result = _kubectl_json(["get", "configmap", name, "-n", namespace, "--ignore-not-found", "-o", "name"])
    if result.returncode:
        raise RuntimeError(f"Could not check ConfigMap '{name}' in namespace '{namespace}'; verify kubeconfig and RBAC")
    if result.stdout.strip():
        raise RuntimeError(f"ConfigMap '{name}' already exists; use existing references for upgrades")
    document = {"apiVersion": "v1", "kind": "ConfigMap",
                "metadata": {"namespace": namespace, "name": name},
                "data": data}
    result = _kubectl_json(["create", "-f", "-"], stdin=json.dumps(document))
    if result.returncode:
        raise RuntimeError(f"Creating ConfigMap '{name}' failed; inspect Kubernetes status without exposing credentials")


def ask(label):
    value = input(label + ": ").strip()
    if not value:
        raise ValueError("Every requested non-secret field is required")
    return value


def choose(label, options, default):
    value = input(f"{label} [{'/'.join(options)}, default: {default}]: ").strip().lower() or default
    if value not in options:
        raise ValueError(f"Unsupported {label} choice; pick one of: {', '.join(options)}")
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


def ask_default(label, default=""):
    prompt = f"{label} [{default}]: " if default else label + ": "
    value = input(prompt).strip()
    return value or default


def has_default_storageclass():
    jsonpath = (r'jsonpath={.items[?(@.metadata.annotations.storageclass\.kubernetes\.io'
                r'/is-default-class=="true")].metadata.name}')
    result = _kubectl_json(["get", "storageclass", "-o", jsonpath])
    return result.returncode == 0 and bool(result.stdout.strip())


def first_node():
    result = _kubectl_json(["get", "nodes", "-o", "jsonpath={.items[0].metadata.name}"])
    return result.stdout.strip() if result.returncode == 0 else ""


def leftover_local_pvs():
    found = []
    for name in ("openan-postgres-pv", "openan-rc-pv", "openan-oc-pv"):
        result = _kubectl_json(["get", "pv", name, "-o", "name"])
        if result.returncode == 0 and result.stdout.strip():
            found.append(name)
    return found


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

    # --- 1b. Image tags (shared default, or one per component) ---------------
    tags = {"registry": tag, "orchestration": tag, "frontend": tag}
    if choose("image tags", ["shared", "per-component"], "shared") == "per-component":
        for name in list(enabled) + (["frontend"] if components["orchestration"] else []):
            tags[name] = ask_default(f"{name} image tag", tag)

    # --- 2. SQL and storage (automatic; not asked) ---------------------------
    # Evaluation always uses in-cluster PostgreSQL; external SQL deployments
    # use reviewed values (see deployment.yaml.example).
    storage_node = None
    local_storage_class = "openan-local"
    if has_default_storageclass():
        print("  Cluster has a default StorageClass; claims use it as-is")
    else:
        print("  No default StorageClass found; enabling the local hostPath fallback")
        for pv in leftover_local_pvs():
            print(f"  Warning: leftover PV '{pv}' detected. If it still holds data (e.g. stale"
                  " pgdata), in-cluster SQL users keep their OLD passwords;"
                  " remove the PV and its hostPath data first (uninstall.sh can clean it)")
        # Empty result must disable the fallback, not deploy a nodeless PV.
        storage_node = first_node() or None
        if storage_node:
            print(f"  Local evaluation storage: {local_storage_class} StorageClass +"
                  f" node-pinned hostPath PVs on {storage_node}"
                  " (postgres, registry, orchestration)")
        else:
            print("  Warning: no node name detectable; claims are left unbound."
                  " Provide a StorageClass or configure persistence in reviewed values")

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

    # The Ingress host is not asked: the evaluation wizard always uses the
    # empty catch-all host so the platform is reachable directly at the
    # LoadBalancer IP. Host-based routing / HTTPS need reviewed values
    # (ingress.host must be a DNS name; Kubernetes rejects IP hosts).

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

    in_cluster_password = secret_input("PostgreSQL password (shared by the seeded app users)")
    if len(in_cluster_password) < 8:
        raise ValueError("PostgreSQL password requires at least 8 characters")

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
    create_secret(namespace, prefix + "pg", {"postgres-password": in_cluster_password})
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
    values = {"namespace": namespace, "frontend": {"image": {"tag": tags["frontend"]}},
              "postgresql": {"enabled": True, "existingSecret": prefix + "pg"},
              "database": {"type": "postgresql"}}
    if storage_node is not None:
        values["postgresql"]["storage"] = {"createStorageClass": True,
                                           "storageClassName": local_storage_class,
                                           "createPV": True, "useHostPath": True,
                                           "nodeName": storage_node}
    if components["registry"]:
        values["registry"] = {"runtimeSecret": prefix + "rc-runtime",
                              "credentialSecret": prefix + "rc-credentials",
                              "modelsConfigMap": models_ref["registry"], "image": {"tag": tags["registry"]}}
        if signing_ref:
            values["registry"]["signing"] = {"mode": "secret", "existingSecret": signing_ref}
        else:
            values["registry"]["signing"] = {"mode": "auto"}
        if storage_node is not None:
            values["registry"]["persistence"] = {
                "storageClassName": local_storage_class, "createPV": True,
                "useHostPath": True, "nodeName": storage_node}
    else:
        values["registry"] = {"enabled": False}
    if components["orchestration"]:
        values["orchestration"] = {"runtimeSecret": prefix + "oc-runtime",
                                   "modelsConfigMap": models_ref["orchestration"],
                                   "image": {"tag": tags["orchestration"]}}
        if agent_registry_url:
            values["orchestration"]["agentRegistryUrl"] = agent_registry_url
        if storage_node is not None:
            values["orchestration"]["persistence"] = {
                "storageClassName": local_storage_class, "createPV": True,
                "useHostPath": True, "nodeName": storage_node}
    else:
        values["orchestration"] = {"enabled": False}
        values["frontend"] = {"enabled": False, "image": {"tag": tags["frontend"]}}
    values["ingress"] = {"host": ""}

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
    except (ValueError, RuntimeError, OSError, EOFError, subprocess.SubprocessError) as error:
        # Concrete reason, never the value: every raise site is audited to
        # exclude secrets (and kubectl stderr, which can echo submitted objects).
        parser.exit(2, f"Configuration failed: {error}\n"
                      "Secret values are never echoed; existing Secrets are not overwritten.\n")
