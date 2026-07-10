# postgres-wal-g

Drop-in `postgres` image with WAL-G baked in. Docker + bash + GitHub Actions only — no app code.

## Testing

```bash
# Fast local entrypoint tests (no image build; runs against upstream postgres:18)
./test/entrypoint_tests.sh

# Full local build (exercises sha256 verification of the wal-g download)
docker build --build-arg POSTGRES_VERSION=18 -t postgres-wal-g:localtest .
```

CI (`test.yml`) additionally does a full backup round-trip against MinIO for pg16–18.

## Entrypoint invariants (test/entrypoint_tests.sh guards these)

- `POSTGRES_*_FILE` vars must pass through untouched — upstream `docker-entrypoint.sh`
  resolves them itself and **hard-errors if both `X` and `X_FILE` are set**. Unwrapping
  them here bricks container startup (shipped bug, fixed in v1.0.1).
- `_FILE` unwrapping strips trailing newlines only; internal newlines must survive
  (armored PGP keys, JSON creds). No `tr -d '\n'`.
- Explicit env wins over `_FILE`.

## Releases

- Push to `main` → `:<pg>-edge` images only.
- Stable tags (`:<pg>`, `:<pg>-<walg>`, `:latest`) publish **only on `v*` tag push**.
  Entrypoint/Dockerfile fixes need a patch tag to reach users.
- New postgres major: bump the matrix in **both** workflows *and* `LATEST_PG` in `build.yml`.

## Version management

- The WAL-G version appears in 4 places (`build.yml` `WAL_G_VERSION_DEFAULT`, `test.yml`,
  `Dockerfile` ARG, README examples). Renovate bumps all of them in lockstep via a regex
  customManager — don't hand-edit one without the others.
- GitHub Actions are pinned to **major tags** (`@v7`), not digests, and Renovate must not
  get `pinDigests: true` — user preference, consistent with other repos (ttyd-base).
