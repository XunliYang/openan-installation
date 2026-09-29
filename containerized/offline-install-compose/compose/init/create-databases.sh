#!/bin/bash
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# All Rights Reserved.
#
# SPDX-License-Identifier: Apache-2.0
#
# Creates the OpenAN databases and roles on first postgres start.
# Mirrors containerized/online-install/openan-chart/templates/postgres/statefulset.yaml.
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<EOSQL
CREATE USER registry WITH PASSWORD '${POSTGRES_PASSWORD}';
CREATE DATABASE registry_center OWNER registry;
GRANT ALL PRIVILEGES ON DATABASE registry_center TO registry;
EOSQL

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<EOSQL
CREATE USER opena2a_t WITH PASSWORD '${POSTGRES_PASSWORD}';
CREATE DATABASE orchestration_center OWNER opena2a_t;
GRANT ALL PRIVILEGES ON DATABASE orchestration_center TO opena2a_t;
EOSQL
