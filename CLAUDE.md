# postgres-wal-g

Drop-in `postgres` image with WAL-G baked in. Docker + bash + GitHub Actions only — no app code.

## Testing

```bash
# Fast local entrypoint tests (no image build; runs against upstream postgres:18)
./test/entrypoint_tests.sh

# Full local build (exercises sha256 verification of the wal-g download)
docker build --build-arg POSTGRES_VERSION=18 -t postgres-wal-g:localtest .
```

CI (`test.yml`) additionally does a full round-trip for pg14–18 against versitygw (MinIO's
images were withdrawn): WAL archiving, backup-push, then restore into a fresh container
with WAL replay. Credentials are passed only via `_FILE`, so it also covers the `wal-g` wrapper.

## Entrypoint invariants (test/entrypoint_tests.sh guards these)

- `POSTGRES_*_FILE` vars must pass through untouched — upstream `docker-entrypoint.sh`
  resolves them itself and **hard-errors if both `X` and `X_FILE` are set**. Unwrapping
  them here bricks container startup (shipped bug, fixed in v1.0.1).
- `_FILE` unwrapping strips trailing newlines only; internal newlines must survive
  (armored PGP keys, JSON creds). No `tr -d '\n'`.
- Explicit env wins over `_FILE`.
- `/usr/local/bin/wal-g` is a symlink to the entrypoint script (real binary: `wal-g.bin`), so
  `docker exec … wal-g` gets unwrapped secrets — exec'd processes skip the entrypoint.
- Path-type vars (`AWS_SHARED_CREDENTIALS_FILE`, `SSL_CERT_FILE`, …) are not unwrapped.
  An unreadable `_FILE` path warns on stderr instead of failing: arbitrary `*_FILE` names
  (e.g. `LOG_FILE`) may legitimately point at files that don't exist yet.

## Releases

- Push to `main` → `:<pg>-edge` images only.
- Stable tags (`:<pg>`, `:<pg>-<walg>`, `:latest`) publish on `v*` tag push, and are rebuilt
  weekly (and on manual dispatch) from the **newest `v*` tag** to pick up upstream postgres
  minor/security updates. Entrypoint/Dockerfile fixes still need a patch tag to reach users.
- No GHCR retention job: `actions/delete-package-versions` matches digests, not tags, and
  counts multi-arch child manifests as versions — it deleted every stable tag once (2026-09).
- New postgres major: bump the matrix in **both** workflows *and* `LATEST_PG` in `build.yml`.

## Version management

- The WAL-G version lives in the `Dockerfile` ARG (single source of truth; `build.yml` parses it
  for tags) plus examples in README and the Dockerfile header. Renovate's regex customManager
  bumps all of them in lockstep.
- wal-g renames release assets occasionally (v3.0.8 dropped `ubuntu-`); a red bump PR usually
  means the download URL in the Dockerfile needs updating.
- GitHub Actions are pinned to **major tags** (`@v7`), not digests, and Renovate must not
  get `pinDigests: true` — user preference, consistent with other repos (ttyd-base).
