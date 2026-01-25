# CloudNativePG TimescaleDB

A CloudNativePG-compatible PostgreSQL container image with TimescaleDB, pgAudit, pg_textsearch, and barman-cloud backup support.

## Image

```
ghcr.io/fincarna/cloudnative-pg-timescaledb:18-2.24.0
```

## Included Components

| Component | Version |
|-----------|---------|
| PostgreSQL | 18 |
| TimescaleDB | 2.24.0 |
| TimescaleDB Toolkit | 1.22.0 |
| pgAudit | 18.0 |
| pg_textsearch | 0.4.1 |
| barman-cloud | 3.17.0 |

## Usage with CloudNativePG

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: timescaledb-cluster
spec:
  instances: 3
  imageName: ghcr.io/fincarna/cloudnative-pg-timescaledb:18-2.24.0

  postgresql:
    shared_preload_libraries:
      - timescaledb
      - pgaudit

  bootstrap:
    initdb:
      postInitTemplateSQL:
        - CREATE EXTENSION IF NOT EXISTS timescaledb;
        - CREATE EXTENSION IF NOT EXISTS timescaledb_toolkit;
        - CREATE EXTENSION IF NOT EXISTS pgaudit;
        - CREATE EXTENSION IF NOT EXISTS pg_textsearch;

  storage:
    size: 10Gi
```

## Backup Configuration

The image includes barman-cloud for object storage backups. Example S3 backup configuration:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: timescaledb-cluster
spec:
  # ... other config ...

  backup:
    barmanObjectStore:
      destinationPath: s3://your-bucket/backups
      s3Credentials:
        accessKeyId:
          name: s3-creds
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: s3-creds
          key: SECRET_ACCESS_KEY
      wal:
        compression: gzip
    retentionPolicy: "7d"
```

## Building Locally

```bash
docker build -t cloudnative-pg-timescaledb:local .
```

## Automated Updates

The image is automatically rebuilt when:
- Changes are pushed to `main` branch
- A new TimescaleDB version is released (checked daily)

## License

Apache-2.0
