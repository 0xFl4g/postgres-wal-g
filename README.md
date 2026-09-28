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
| `<pg>-<walg>` | `18-v3.0.9` | Specific postgres major + WAL-G version. **Use this in production**, pin to digest. |
| `<pg>` | `18` | Newest release for that postgres major. Floating. |
| `latest` | `latest` | Newest release, newest postgres major. Floating. |
| `<pg>-edge` | `18-edge` | Built from `main` on every push. Unreleased, no SLA. |

Release tags are rebuilt weekly from the newest release, so they pick up upstream postgres minor releases and Debian security fixes. The digest behind a tag changes on each rebuild; pin the digest if you need a fixed image.

Supported postgres majors: 14, 15, 16, 17, 18. Multi-arch: `linux/amd64`, `linux/arm64`. Majors follow upstream support: 14 is dropped after its final upstream release (2026-11-12); a new major is added once upstream publishes its image.

## Verifying images

Images published from 2026-09-28 onward are signed with [cosign](https://github.com/sigstore/cosign) keyless signing from this repo's `build.yml`, and carry an SBOM and build provenance. The older `:<pg>-v3.0.5` tags predate this and are unsigned; use the `-v3.0.9` ones.

```bash
cosign verify ghcr.io/0xfl4g/postgres-wal-g:18 \
  --certificate-identity-regexp '^https://github.com/0xFl4g/postgres-wal-g/\.github/workflows/build\.yml@' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

# SBOM (SPDX) and provenance, attached by BuildKit
docker buildx imagetools inspect ghcr.io/0xfl4g/postgres-wal-g:18 --format '{{ json .SBOM }}'
docker buildx imagetools inspect ghcr.io/0xfl4g/postgres-wal-g:18 --format '{{ json .Provenance }}'
```

Images are scanned with Grype before publishing; fixable HIGH/CRITICAL CVEs in OS packages block the release. Findings in the bundled WAL-G binary are only fixable upstream, so they are reported (Security tab) but don't block. See [SECURITY.md](./SECURITY.md).

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
      # pg18+: mount /var/lib/postgresql (data lives in 18/docker below it).
      # pg14–17: mount /var/lib/postgresql/data instead.
      - postgres_data:/var/lib/postgresql
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
# Only read during recovery (see "Restore" below); harmless otherwise.
restore_command = '/usr/local/bin/wal-g wal-fetch %f %p'
```

`archive_mode` requires a postgres **restart** (not reload) to take effect.

## What this image actually adds over `postgres:N`

1. `/usr/local/bin/wal-g` — the postgres-flavoured WAL-G binary at a known path.
2. An entrypoint wrapper that resolves `*_FILE` env vars into their unsuffixed equivalents (Docker-secrets convention), then chains into the standard `docker-entrypoint.sh`. Without this wrapper, `AWS_ACCESS_KEY_ID_FILE=/run/secrets/foo` would be silently ignored by WAL-G. The same wrapper sits in front of `wal-g` itself (the binary is `wal-g.bin`), so `docker exec … wal-g` sees the secrets too.

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

Details:

- Trailing newlines are stripped; internal newlines are preserved, so multi-line secrets (armored PGP keys, JSON credentials) survive intact.
- `POSTGRES_*_FILE` vars are passed through untouched — the official postgres entrypoint resolves those itself (and errors if both `POSTGRES_X` and `POSTGRES_X_FILE` are set).
- Standard path settings whose consumers read the file themselves are also left alone: `AWS_CONFIG_FILE`, `AWS_SHARED_CREDENTIALS_FILE`, `AWS_WEB_IDENTITY_TOKEN_FILE`, `SSL_CERT_FILE`, `WALG_S3_CA_CERT_FILE`.
- A `_FILE` path that can't be read is reported on stderr (`docker logs`) and the variable stays unset.
- Secret files must be readable by whoever runs `wal-g`: root at startup, `postgres` for `docker exec -u postgres`.

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

CI exercises the S3 API against [versitygw](https://github.com/versity/versitygw) (backup, WAL archiving, restore with WAL replay); the rows above are not covered by CI. If you've validated one of the "not yet" rows, open a PR.

## Common operations

Run `wal-g` as the `postgres` user: as root it connects to postgres as role `root`, which doesn't exist.

```bash
# Take a base backup
docker compose exec -u postgres postgres sh -c 'wal-g backup-push "$PGDATA"'

# List base backups
docker compose exec -u postgres postgres wal-g backup-list

# List archived WAL segments
docker compose exec -u postgres postgres wal-g st ls wal_005/

# Trim old archives
docker compose exec -u postgres postgres wal-g delete retain FULL 7 --confirm
```

### Restore

Restores the LATEST base backup, then replays all archived WAL on startup. **This deletes the current data directory.** Needs `restore_command` in `postgresql.conf` (see above).

```bash
docker compose stop postgres
docker compose run --rm -u postgres postgres sh -c '
  find "$PGDATA" -mindepth 1 -delete 2>/dev/null
  wal-g backup-fetch "$PGDATA" LATEST && touch "$PGDATA/recovery.signal"'
docker compose up -d postgres   # replays WAL, then promotes
```

Run it as `postgres`, not root: on pg18 a root-run fetch creates the parent `18/` directory root-owned, and postgres then can't start. For point-in-time recovery, also set `recovery_target_time` before starting. See the [WAL-G PITR docs](https://wal-g.readthedocs.io/PostgreSQL/#point-in-time-recovery).

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
  --build-arg WAL_G_VERSION=v3.0.9 \
  -t postgres-wal-g:local-18 \
  .
```

## License

MIT. See [LICENSE](./LICENSE).

This image bundles unmodified binaries from:
- [`postgres`](https://hub.docker.com/_/postgres) — PostgreSQL License
- [`wal-g`](https://github.com/wal-g/wal-g) — Apache License 2.0
