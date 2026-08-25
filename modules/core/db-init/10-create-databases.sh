#!/bin/bash
# Runs once on first Postgres boot (docker-entrypoint-initdb.d).
# One Postgres instance, separate databases per module (Decision 19 / §2.1):
# sentinel (created via POSTGRES_DB), authentik, vaultwarden, vibe_print.
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE DATABASE authentik;
    CREATE DATABASE vaultwarden;
    CREATE DATABASE vibe_print;
    GRANT ALL PRIVILEGES ON DATABASE authentik  TO $POSTGRES_USER;
    GRANT ALL PRIVILEGES ON DATABASE vaultwarden TO $POSTGRES_USER;
    GRANT ALL PRIVILEGES ON DATABASE vibe_print  TO $POSTGRES_USER;
EOSQL
