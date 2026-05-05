# Stage 1: Base PostgreSQL installation
FROM debian:bookworm-slim AS base

LABEL org.opencontainers.image.source="https://github.com/fincarna/cloudnative-pg-timescaledb"
LABEL org.opencontainers.image.description="CloudNativePG-compatible PostgreSQL with TimescaleDB, pgAudit, pg_textsearch, pgmq, pg_partman, and barman-cloud"
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

# Stage 2: Extensions (TimescaleDB + Toolkit + pgAudit + pg_textsearch + pgmq + pg_partman)
FROM base AS extensions

ARG PG_MAJOR=18
ARG TIMESCALEDB_VERSION=2.24.0
ARG TIMESCALEDB_TOOLKIT_VERSION=1.22.0
ARG PG_TEXTSEARCH_VERSION=0.4.1
ARG PGMQ_VERSION=v1.8.0
ARG PG_PARTMAN_VERSION=v5.1.0
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

# Build + install pgmq and pg_partman from source. pgmq v1.8.0 (Mar 2026)
# dropped pgrx in favor of a pure-SQL extension that also added PG18
# support; pg_partman is its runtime dependency for queue partitioning.
# Build dependencies are installed and removed inside this single RUN
# layer so they don't bloat the image.
#
# pgmq quirk: the Makefile generates `sql/pgmq--$(EXTVERSION).sql` (the
# CREATE EXTENSION install script) at build-time via `cp`, but its
# install target's DATA list is captured before the `cp` runs — so the
# per-version base install file is built but not installed. Without
# the explicit copy below, `CREATE EXTENSION pgmq` fails with "no
# installation script for version $EXTVERSION".
RUN set -ex; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential \
        git \
        postgresql-server-dev-${PG_MAJOR} \
    ; \
    # pg_partman — pgmq's runtime dependency. NO_BGW=1 skips the
    # background-worker shared library; pgmq calls partman's SQL
    # maintenance functions on demand, so the BGW isn't required.
    git clone --depth 1 --branch "${PG_PARTMAN_VERSION}" \
        https://github.com/pgpartman/pg_partman.git /tmp/pg_partman; \
    make -C /tmp/pg_partman NO_BGW=1 install; \
    rm -rf /tmp/pg_partman; \
    # pgmq — pure SQL, no Rust toolchain.
    git clone --depth 1 --branch "${PGMQ_VERSION}" \
        https://github.com/pgmq/pgmq.git /tmp/pgmq; \
    make -C /tmp/pgmq/pgmq-extension install; \
    PGMQ_EXTVERSION=$(grep "^default_version" /tmp/pgmq/pgmq-extension/pgmq.control \
        | sed -r "s/default_version[^']+'([^']+).*/\1/"); \
    install -m 644 \
        "/tmp/pgmq/pgmq-extension/sql/pgmq--${PGMQ_EXTVERSION}.sql" \
        "/usr/share/postgresql/${PG_MAJOR}/extension/"; \
    rm -rf /tmp/pgmq; \
    # Drop build deps so they don't carry into the runtime image.
    apt-get purge -y --auto-remove \
        build-essential \
        git \
        postgresql-server-dev-${PG_MAJOR} \
    ; \
    apt-get clean; \
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
