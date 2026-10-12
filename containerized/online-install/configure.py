#!/usr/bin/env python3
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""Guided HTTP evaluation configuration; secrets only in memory and kubectl stdin.

Production/custom HTTPS profiles use reviewed values and existing Secrets instead.
No defaults for passwords, no credential arguments, no Secret overwrite.
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


def create_secret(namespace, name, values):
    result = subprocess.run(
        ["kubectl", "get", "secret", name, "-n", namespace, "--ignore-not-found", "-o", "name"],
        capture_output=True, text=True,
    )
    if result.returncode or result.stdout.strip():
        raise RuntimeError("Secret lookup failed or a Secret already exists; use reviewed values for upgrades")
    document = {"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
                "metadata": {"namespace": namespace, "name": name},
                "data": {key: base64.b64encode(value.encode()).decode() for key, value in values.items()}}
    result = subprocess.run(["kubectl", "create", "-f", "-"], input=json.dumps(document),
                            capture_output=True, text=True)
    if result.returncode:
        # Kubernetes error output can include submitted objects; never echo it.
        raise RuntimeError("Secret creation failed; inspect Kubernetes audit/status without exposing credentials")


def ask(label):
    value = input(label + ": ").strip()
    if not value:
        raise ValueError("Every requested non-secret field is required")
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


def configure(namespace, release, output):
    if not output.parent.is_dir():
        raise ValueError("Output parent directory must already exist")
    if output.exists():
        raise ValueError("Output exists; refusing to overwrite deployment configuration")
    tag = ask("Compatible application image tag (already pushed)")
    db_type = ask("External SQL type: mysql or postgresql")
    if db_type not in {"mysql", "postgresql"}:
        raise ValueError("Unsupported SQL type")
    host = ask("External SQL host")
    port = int(ask("External SQL port"))
    if not 1 <= port <= 65535:
        raise ValueError("SQL port must be 1..65535")
    names = {component: ask(component + " database name") for component in ("registry", "orchestration")}
    if names["registry"] == names["orchestration"]:
        raise ValueError("Use separate database names")
    users = {component: ask(component + " database username") for component in names}
    models = {component: ask(component + " existing models.yaml ConfigMap") for component in names}
    signing = ask("Existing registry signing Secret (sign.cer, sign_key.pem, cert_pwd)")
    ingress_host = ask("Public HTTP evaluation hostname")
    # Check public dependencies before collecting/creating any credentials.
    for kind, name in [("configmap", models["registry"]), ("configmap", models["orchestration"]), ("secret", signing)]:
        result = subprocess.run(["kubectl", "get", kind, name, "-n", namespace, "-o", "name"],
                                capture_output=True, text=True)
        if result.returncode:
            raise ValueError("Required model/signing reference is missing or inaccessible")
    passwords = {component: secret_input(component + " SQL password") for component in names}
    admin = secret_input("Initial admin password (change it in the web UI before API use)")
    if len(admin) < 12 or not all(re.search(p, admin) for p in (r"[a-z]", r"[A-Z]", r"[0-9]", r"[^a-zA-Z0-9]")):
        raise ValueError("Initial password requires 12+ characters and lower/upper/digit/special classes")
    token, hmac_key, fingerprint = (secrets.token_urlsafe(48) for _ in range(3))
    credential = ("credential.orchestration.identity=orchestration-service\n"
                  "credential.orchestration.role=partner_service\n"
                  "credential.orchestration.enabled=true\ncredential.orchestration.token_hash="
                  + hmac.new(hmac_key.encode(), token.encode(), hashlib.sha256).hexdigest() + "\n")
    # Namespace creation is idempotent and carries no secret material.
    ns = subprocess.run(["kubectl", "create", "namespace", namespace, "--dry-run=client", "-o", "json"],
                        capture_output=True, text=True, check=True)
    subprocess.run(["kubectl", "apply", "-f", "-"], input=ns.stdout, text=True, check=True)
    prefix = release + "-"
    material = {prefix + "rc-db": {"db-password": passwords["registry"]},
                prefix + "oc-db": {"db-password": passwords["orchestration"]},
                prefix + "rc-runtime": {"INTEGRATION_TOKEN_HMAC_KEY": hmac_key, "INTEGRATION_FINGERPRINT_KEY": fingerprint},
                prefix + "rc-credentials": {"integration_credentials.conf": credential},
                prefix + "oc-runtime": {"OC_ADMIN_INITIAL_PASSWORD": admin, "REGISTRY_ACCESS_TOKEN": token}}
    for name, data in material.items():
        create_secret(namespace, name, data)
    values = {"namespace": namespace, "postgresql": {"enabled": False},
              "database": {"type": db_type, "host": host, "port": port},
              "registry": {"runtimeSecret": prefix + "rc-runtime", "credentialSecret": prefix + "rc-credentials",
                           "modelsConfigMap": models["registry"], "signing": {"mode": "secret", "existingSecret": signing},
                           "image": {"tag": tag}},
              "orchestration": {"runtimeSecret": prefix + "oc-runtime", "modelsConfigMap": models["orchestration"],
                                "image": {"tag": tag}},
              "frontend": {"image": {"tag": tag}}, "ingress": {"host": ingress_host}}
    for component in names:
        values["database"][component] = {"name": names[component], "username": users[component],
                                          "existingSecret": prefix + ("rc-db" if component == "registry" else "oc-db")}
    # Only non-secret JSON/YAML-compatible values. Exclusive creation preserves operator files.
    with output.open("x", encoding="utf-8") as stream:
        json.dump(values, stream, indent=2)
    print("Non-secret values created. Secrets are stored only in Kubernetes. Use reviewed HTTPS values for production.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--namespace", required=True)
    parser.add_argument("--release", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    for name in (args.namespace, args.release):
        if not re.fullmatch(r"[a-z0-9](?:[-a-z0-9]*[a-z0-9])?", name) or len(name) > 53:
            parser.error("Invalid namespace/release")
    try:
        configure(args.namespace, args.release, args.output)
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError):
        parser.exit(2, "Configuration failed without exposing secret values; existing Secrets are not overwritten.\n")
