#!/bin/sh
set -eu

cd /workspace

defaults_file="$(mktemp)"
trap 'rm -f "$defaults_file"' EXIT
chmod 600 "$defaults_file"

printf '%s\n' \
    '[client]' \
    'host=127.0.0.1' \
    'user=root' \
    "password=$MYSQL_ROOT_PASSWORD" \
    'local-infile=1' \
    > "$defaults_file"

mysql \
    --defaults-extra-file="$defaults_file" \
    < tests/run_sample_idempotency.sql

mysql \
    --defaults-extra-file="$defaults_file" \
    < tests/run_constraint_failures.sql
