# Stage 1: Base PostgreSQL installation
FROM debian:bookworm-slim AS base

LABEL org.opencontainers.image.source="https://github.com/fincarna/cloudnative-pg-timescaledb"
LABEL org.opencontainers.image.description="CloudNativePG-compatible PostgreSQL with TimescaleDB, pgAudit, pg_textsearch, and barman-cloud"
LABEL org.opencontainers.image.licenses="Apache-2.0"

ARG PG_MAJOR=18

RUN set -ex; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        locales \
        gosu \
    ; \
    # Generate locale
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen; \
    # Add PostgreSQL APT repository
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/pgdg.gpg; \
    echo "deb [signed-by=/usr/share/keyrings/pgdg.gpg] http://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" > /etc/apt/sources.list.d/pgdg.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        postgresql-${PG_MAJOR} \
        postgresql-client-${PG_MAJOR} \
        postgresql-common \
    ; \
    rm -rf /var/lib/apt/lists/*; \
    # Set postgres user/group to UID/GID 26 (CloudNativePG convention)
    # Remove the 'tape' group which occupies GID 26 on Debian
    groupdel tape; \
    usermod -u 26 postgres; \
    groupmod -g 26 postgres; \
    chown -R postgres:postgres /var/lib/postgresql

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV PATH="/usr/lib/postgresql/${PG_MAJOR}/bin:${PATH}"
ENV PGDATA=/var/lib/postgresql/data

# Stage 2: Extensions (TimescaleDB + Toolkit + pgAudit + pg_textsearch)
FROM base AS extensions

ARG PG_MAJOR=18
ARG TIMESCALEDB_VERSION=2.24.0
ARG TIMESCALEDB_TOOLKIT_VERSION=1.22.0
ARG PG_TEXTSEARCH_VERSION=0.4.1
ARG TARGETARCH

RUN set -ex; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        unzip \
    ; \
    # Add TimescaleDB APT repository
    curl -fsSL https://packagecloud.io/timescale/timescaledb/gpgkey | gpg --dearmor -o /usr/share/keyrings/timescaledb.gpg; \
    echo "deb [signed-by=/usr/share/keyrings/timescaledb.gpg] https://packagecloud.io/timescale/timescaledb/debian/ bookworm main" > /etc/apt/sources.list.d/timescaledb.list; \
    apt-get update; \
    # Install TimescaleDB
    apt-get install -y --no-install-recommends \
        timescaledb-2-postgresql-${PG_MAJOR}=${TIMESCALEDB_VERSION}~debian12* \
    ; \
    # Install TimescaleDB Toolkit
    apt-get install -y --no-install-recommends \
        timescaledb-toolkit-postgresql-${PG_MAJOR} \
    ; \
    # Install pgAudit from PGDG
    apt-get install -y --no-install-recommends \
        postgresql-${PG_MAJOR}-pgaudit \
    ; \
    # Install pg_textsearch from GitHub releases (contains a .deb package)
    curl -fsSL "https://github.com/timescale/pg_textsearch/releases/download/v${PG_TEXTSEARCH_VERSION}/pg-textsearch-v${PG_TEXTSEARCH_VERSION}-pg${PG_MAJOR}-${TARGETARCH}.zip" -o /tmp/pg_textsearch.zip; \
    unzip /tmp/pg_textsearch.zip -d /tmp/pg_textsearch; \
    dpkg -i /tmp/pg_textsearch/*.deb; \
    rm -rf /tmp/pg_textsearch /tmp/pg_textsearch.zip; \
    apt-get purge -y --auto-remove unzip; \
    rm -rf /var/lib/apt/lists/*

# Stage 3: Barman Cloud for backup support
FROM extensions AS final

ARG BARMAN_VERSION=3.17.0

RUN set -ex; \
    apt-get update; \
    # Ensure all system packages have latest security patches
    apt-get upgrade -y; \
    apt-get install -y --no-install-recommends \
        python3 \
        python3-pip \
        python3-dev \
        gcc \
        libpq-dev \
    ; \
    # Upgrade wheel to fix CVE-2026-24049 (file permission vulnerability)
    pip3 install --break-system-packages --no-cache-dir \
        "wheel>=0.46.2" \
    ; \
    pip3 install --break-system-packages --no-cache-dir \
        "barman[cloud,azure,snappy,google,zstandard,lz4]==${BARMAN_VERSION}" \
    ; \
    # Remove build dependencies to reduce image size
    apt-get purge -y --auto-remove \
        python3-dev \
        gcc \
    ; \
    # Remove pip and wheel (no longer needed at runtime)
    pip3 install --break-system-packages --no-cache-dir pip==0.1 2>/dev/null || true; \
    apt-get purge -y --auto-remove python3-pip; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /root/.cache /usr/lib/python3/dist-packages/wheel*

# Add entrypoint script for standalone usage
COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Ensure directories have correct ownership
RUN set -ex; \
    mkdir -p /var/run/postgresql; \
    chown -R postgres:postgres /var/run/postgresql; \
    chmod 3777 /var/run/postgresql; \
    mkdir -p "$PGDATA"; \
    chown -R postgres:postgres "$PGDATA"; \
    chmod 700 "$PGDATA"

USER 26

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["postgres"]
