#!/bin/bash
set -e

# If running as root, switch to postgres user
if [ "$(id -u)" = '0' ]; then
    exec gosu postgres "$BASH_SOURCE" "$@"
fi

# If first argument is 'postgres' or starts with '-', handle initialization
if [ "${1:0:1}" = '-' ] || [ "$1" = 'postgres' ]; then
    # Check if data directory needs initialization
    if [ ! -s "$PGDATA/PG_VERSION" ]; then
        echo "Initializing PostgreSQL database..."

        # Initialize the database
        initdb --username=postgres --pwfile=<(echo "${POSTGRES_PASSWORD:-postgres}")

        # Configure authentication
        {
            echo "host all all all scram-sha-256"
        } >> "$PGDATA/pg_hba.conf"

        # Configure shared_preload_libraries if not overridden in command
        if ! grep -q "shared_preload_libraries" "$PGDATA/postgresql.conf"; then
            echo "shared_preload_libraries = 'timescaledb'" >> "$PGDATA/postgresql.conf"
        fi

        # Allow connections from anywhere
        echo "listen_addresses = '*'" >> "$PGDATA/postgresql.conf"

        # Start temporarily to create user/database
        pg_ctl -D "$PGDATA" -o "-c listen_addresses=''" -w start

        # Create user if specified
        if [ -n "$POSTGRES_USER" ] && [ "$POSTGRES_USER" != 'postgres' ]; then
            psql -v ON_ERROR_STOP=1 --username postgres <<-EOSQL
                CREATE USER "$POSTGRES_USER" WITH SUPERUSER PASSWORD '${POSTGRES_PASSWORD:-postgres}';
EOSQL
        fi

        # Create database if specified
        if [ -n "$POSTGRES_DB" ] && [ "$POSTGRES_DB" != 'postgres' ]; then
            psql -v ON_ERROR_STOP=1 --username postgres <<-EOSQL
                CREATE DATABASE "$POSTGRES_DB" OWNER "${POSTGRES_USER:-postgres}";
EOSQL
        elif [ -n "$POSTGRES_USER" ] && [ "$POSTGRES_USER" != 'postgres' ]; then
            # Create database with same name as user
            psql -v ON_ERROR_STOP=1 --username postgres <<-EOSQL
                CREATE DATABASE "$POSTGRES_USER" OWNER "$POSTGRES_USER";
EOSQL
        fi

        pg_ctl -D "$PGDATA" -m fast -w stop

        echo "PostgreSQL initialization complete."
    fi
fi

exec "$@"
