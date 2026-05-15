# postgres-wal-g

A drop-in replacement for the official `postgres` Docker image with [WAL-G](https://github.com/wal-g/wal-g) baked in for continuous WAL archiving and point-in-time recovery (PITR).

Built because there is no current official `postgres + WAL-G` image. The closest community option ships PostgreSQL 17; the others are stale or single-version. This repo aims to keep parity with the upstream `postgres` image's release cadence.

## Images

Published to GHCR. Pull with:

```bash
docker pull ghcr.io/0xfl4g/postgres-wal-g:18
```

| Tag pattern | Example | Meaning |
|---|---|---|
| `<pg>-<walg>` | `18-v3.0.5` | Specific postgres major + WAL-G version. **Use this in production**, pin to digest. |
| `<pg>` | `18` | Latest WAL-G build for that postgres major. Floating, follows tag pushes. |
| `latest` | `latest` | Latest postgres major + latest WAL-G. Floating. |
| `<pg>-edge` | `18-edge` | Built from `main` on every push. Untagged, no SLA. |

Supported postgres majors: 14, 15, 16, 17, 18. Multi-arch: `linux/amd64`, `linux/arm64`.

## Quickstart

```yaml
# docker-compose.yml
services:
  postgres:
    image: ghcr.io/0xfl4g/postgres-wal-g:18
    environment:
      POSTGRES_PASSWORD: secret
      # WAL-G — point at any S3-compatible bucket. Empty value disables.
      WALG_S3_PREFIX: s3://my-bucket/wal-g
      AWS_ENDPOINT: https://s3.example.com
      AWS_REGION: auto
      AWS_S3_FORCE_PATH_STYLE: "true"
      # Either set creds inline...
      AWS_ACCESS_KEY_ID: ...
      AWS_SECRET_ACCESS_KEY: ...
      # ...or use the Docker-secrets convention (see "Secrets" below)
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./postgresql.conf:/etc/postgresql/postgresql.conf:ro
    command: ["postgres", "-c", "config_file=/etc/postgresql/postgresql.conf"]

volumes:
  postgres_data:
```

`postgresql.conf` minimum for PITR:

```ini
wal_level = replica
archive_mode = on
archive_command = '/usr/local/bin/wal-g wal-push %p'
archive_timeout = 60s
```

`archive_mode` requires a postgres **restart** (not reload) to take effect.

## What this image actually adds over `postgres:N`

1. `/usr/local/bin/wal-g` — the postgres-flavoured WAL-G binary at a known path.
2. An entrypoint wrapper that resolves `*_FILE` env vars into their unsuffixed equivalents (Docker-secrets convention), then chains into the standard `docker-entrypoint.sh`. Without this wrapper, `AWS_ACCESS_KEY_ID_FILE=/run/secrets/foo` would be silently ignored by WAL-G.

That's it. No Patroni, no custom replication scripts, no opinions about backup scheduling. WAL-G is dormant until you configure `archive_command` — until then this image behaves identically to upstream `postgres`.

## Secrets

Any env var ending in `_FILE` is unwrapped before postgres starts. The file's contents (trailing newlines stripped) become the env var of the same name without the suffix.

```yaml
services:
  postgres:
    image: ghcr.io/0xfl4g/postgres-wal-g:18
    environment:
      WALG_S3_PREFIX: s3://my-bucket/wal-g
      AWS_ENDPOINT: https://s3.example.com
      AWS_REGION: auto
      AWS_S3_FORCE_PATH_STYLE: "true"
      AWS_ACCESS_KEY_ID_FILE: /run/secrets/s3_access_key
      AWS_SECRET_ACCESS_KEY_FILE: /run/secrets/s3_secret_key
      POSTGRES_PASSWORD_FILE: /run/secrets/postgres_password
    secrets:
      - s3_access_key
      - s3_secret_key
      - postgres_password

secrets:
  s3_access_key:
    file: ./secrets/s3_access_key
  s3_secret_key:
    file: ./secrets/s3_secret_key
  postgres_password:
    file: ./secrets/postgres_password
```

Explicit env values win over `_FILE` — if both `AWS_ACCESS_KEY_ID` and `AWS_ACCESS_KEY_ID_FILE` are set, the explicit value is kept.

## Tested S3 backends

| Backend | Tested | Notes |
|---|---|---|
| AWS S3 | ✓ | Default WAL-G behaviour. |
| Cloudflare R2 | ✓ | Set `AWS_S3_FORCE_PATH_STYLE=true`, `AWS_REGION=auto`, `AWS_ENDPOINT=https://<account>.r2.cloudflarestorage.com`. |
| Backblaze B2 (S3 API) | ✓ | Set `AWS_ENDPOINT` to the B2 S3 endpoint, `AWS_REGION` to your bucket region. |
| MinIO | ✓ | Set `AWS_S3_FORCE_PATH_STYLE=true`. |
| Storj DCS | ✓ | Via the S3 gateway at `gateway.storjshare.io`. |
| Google Cloud Storage | not yet | WAL-G supports it natively (`WALG_GS_PREFIX`), should work but untested. |
| Azure Blob | not yet | Same. |

If you've validated one of the "not yet" rows, open a PR.

## Common operations

```bash
# Take a base backup (run inside the postgres container)
docker compose exec postgres wal-g backup-push /var/lib/postgresql/data

# List base backups
docker compose exec postgres wal-g backup-list

# List archived WAL segments
docker compose exec postgres wal-g st ls wal_005/

# Restore (into an empty data dir) to LATEST backup + all available WAL
docker compose run --rm postgres wal-g backup-fetch /var/lib/postgresql/data LATEST

# Trim old archives
docker compose exec postgres wal-g delete retain FULL 7 --confirm
```

PITR restore uses `recovery_target_time` in `postgresql.auto.conf` + a `recovery.signal` file in the data dir. See the [WAL-G PITR docs](https://wal-g.readthedocs.io/PostgreSQL/#point-in-time-recovery) for the full procedure.

## What this image does NOT include

- **A backup scheduler.** Run `wal-g backup-push` from cron / systemd / the postgres host, or wire it into your existing backup orchestration.
- **Monitoring.** Set up Prometheus alerts on `pg_stat_archiver_failed_count` — a failing `archive_command` halts WAL recycling and *will* fill your disk. This is non-optional.
- **Encryption keys.** WAL-G supports libsodium encryption via `WALG_LIBSODIUM_KEY_PATH`. Generate and rotate the key yourself; the image doesn't bake one in.

## Comparison to other images

| Image | Status | Source |
|---|---|---|
| `wal-g/wal-g` upstream | Ships the binary only, no postgres-bundled image | [github.com/wal-g/wal-g](https://github.com/wal-g/wal-g) |
| `koehn/postgres-wal-g` | PG17 default, single maintainer, alpine-based | [git.koehn.com](https://git.koehn.com/docker/postgres-wal-g) |
| `zalando/spilo` | Full HA stack (Patroni + WAL-G/WAL-E), Debian-based, heavy | [github.com/zalando/spilo](https://github.com/zalando/spilo) |
| **this repo** | PG14–18, multi-arch, simple `_FILE` secret support | here |

If you want HA postgres with automatic failover, use Spilo. If you want a single-instance postgres + S3 backup that fits in a `docker compose up`, use this.

## Why this is third-party

The cleanest place for a "postgres + wal-g" image would be in the wal-g project itself. Until upstream decides to ship one, this repo is the workaround. If wal-g ever publishes their own combined image, this repo will defer to it.

## Building locally

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --build-arg POSTGRES_VERSION=18 \
  --build-arg WAL_G_VERSION=v3.0.5 \
  -t postgres-wal-g:local-18 \
  .
```

## License

MIT. See [LICENSE](./LICENSE).

This image bundles unmodified binaries from:
- [`postgres`](https://hub.docker.com/_/postgres) — PostgreSQL License
- [`wal-g`](https://github.com/wal-g/wal-g) — Apache License 2.0
