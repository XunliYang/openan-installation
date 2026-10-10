#!/bin/bash
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# All Rights Reserved.
#
# SPDX-License-Identifier: Apache-2.0
#
# Creates the OpenAN databases and roles on first postgres start.
# Mirrors containerized/online-install/openan-chart/templates/postgres/statefulset.yaml.
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" \
  -v password="$REGISTRY_DB_PASSWORD" -v dbuser="$REGISTRY_DB_USERNAME" -v dbname="$REGISTRY_DB_NAME" <<'EOSQL'
CREATE USER :"dbuser" WITH PASSWORD :'password';
CREATE DATABASE :"dbname" OWNER :"dbuser";
GRANT ALL PRIVILEGES ON DATABASE :"dbname" TO :"dbuser";
EOSQL

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" \
  -v password="$ORCH_DB_PASSWORD" -v dbuser="$ORCH_DB_USERNAME" -v dbname="$ORCH_DB_NAME" <<'EOSQL'
CREATE USER :"dbuser" WITH PASSWORD :'password';
CREATE DATABASE :"dbname" OWNER :"dbuser";
GRANT ALL PRIVILEGES ON DATABASE :"dbname" TO :"dbuser";
EOSQL
