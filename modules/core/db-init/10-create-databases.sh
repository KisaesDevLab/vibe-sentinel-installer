#!/bin/bash
# Runs once on first Postgres boot (docker-entrypoint-initdb.d).
# One Postgres instance, separate databases per module (Decision 19 / §2.1):
# sentinel (created via POSTGRES_DB), authentik, vaultwarden.
#
# `vibe_print` was dropped on 2026-08-28: the print module now runs the image
# the Vibe-Printer repo actually publishes, which is single-process SQLite by
# design. Creating an unused database here would have been harmless but
# misleading - an empty schema that looks like somewhere print data lives.
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE DATABASE authentik;
    CREATE DATABASE vaultwarden;
    GRANT ALL PRIVILEGES ON DATABASE authentik   TO $POSTGRES_USER;
    GRANT ALL PRIVILEGES ON DATABASE vaultwarden TO $POSTGRES_USER;
EOSQL
