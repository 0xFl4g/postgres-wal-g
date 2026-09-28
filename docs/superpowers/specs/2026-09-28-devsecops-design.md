# DevOps / DevSecOps hardening — design

Date: 2026-09-28 · Scope: this repo (`postgres-wal-g`) only · Status: approved in chat, pending spec review

## Goal

A hardened pipeline for a public image: every published image is vulnerability-gated,
signed, and carries an SBOM + provenance; `main` only receives CI-verified changes;
dependencies stay current with minimal human effort. Low maintenance is a requirement —
no gate that fails weekly on unfixable upstream Debian CVEs.

## Decisions (from brainstorming)

| Topic | Decision |
|---|---|
| Scope | This repo only. The 4 other repos' no-op `ignore-versions` is a separate follow-up. |
| CVE gate | Block publishing on **fixable HIGH/CRITICAL in OS (deb) packages** only; report everything (incl. Go binaries) to the Security tab. Go-module findings (wal-g, gosu) are only fixable upstream — verified 2026-09-28: 9 fixable HIGH, all in `/usr/local/bin/wal-g.bin`, 0 in deb. They clear via Renovate wal-g bumps. |
| `main` protection | PR + all required checks green; no approvals; no force-push/deletion; admin bypass. |
| Updates | Renovate automerges minor/patch after all checks pass; majors manual. Actions are pinned `@vN`, so they only ever get major bumps — automerge effectively applies to WAL-G. |
| Scanner | **Grype** via `anchore/scan-action@v7`. Trivy rejected: GHSA-69fq-xp46-6x23 (2026-03-21, critical, "Trivy ecosystem supply chain temporarily compromised"). |
| Action pinning | Unchanged: major tags (`@vN`), never digests (user preference). Mitigated by job isolation + `minimumReleaseAge`. |

## Current state (verified 2026-09-28)

- Up to date: WAL-G v3.0.9 (latest), all actions on latest majors.
- `postgres:19` not published (only `19beta1`). Secret scanning + push protection on.
- No rulesets/branch protection, no scanning, SBOM, signing, or CI linting;
  `test/entrypoint_tests.sh` runs only locally.

## 1. Pipeline

### `build.yml` — split into two jobs (least privilege)

The third-party scanner must never run in a job that can push or sign.

**Job `scan`** (matrix pg14–18) — `permissions: contents: read, security-events: write`
1. checkout (`persist-credentials: false`); for schedule/dispatch, check out newest `v*` tag (existing logic).
   Job outputs `sha` (the checked-out commit) and `walg` (version) so `publish` builds the same source.
2. Resolve WAL-G version from the Dockerfile (existing).
3. Build amd64 image, `load: true`, `cache-to: type=gha,mode=max,scope=pg<N>`.
4. **Report scan** (Grype, `fail-build: false`, all findings, SARIF) + upload to code scanning,
   category `grype-pg<N>`. Upload is skipped for fork PRs (their token can't write security events).
5. **Gate scan** (Grype, `only-fixed: true`, `severity-cutoff: high`, `fail-build: true`) with a config
   ignoring `type: go-module`. The config is written to `$RUNNER_TEMP` by the workflow, not read from
   the repo, because scheduled rebuilds check out older tags that don't contain it.
6. Smoke test (existing: `wal-g --version`, `postgres --version`).
7. PRs only: QEMU arm64 build, `push: false`.

**Job `publish`** (`needs: scan`, same matrix, skipped on `pull_request`) —
`permissions: contents: read, packages: write, id-token: write`
1. checkout + same tag/version resolution as `scan` (must build the same source).
2. Compute tags (existing logic).
3. QEMU + Buildx; multi-arch build-and-push from the shared GHA cache, with
   `sbom: true` and `provenance: mode=max`.
4. Install cosign (`sigstore/cosign-installer@v3`), `cosign sign --yes <image>@<digest>`
   (keyless, same pattern as byte-medusa-backend).

Pull requests: `scan` runs (gate + smoke + arm64 build check); `publish` is skipped.
`publish` needs the whole `scan` matrix, so one major failing the gate blocks publishing for
all majors in that run — accepted for simplicity.

Weekly rebuild failing the gate: previous images stay published; GitHub emails the failure.

### New `lint.yml` (PRs + push to main) — `permissions: contents: read`

Jobs: `actionlint`, `shellcheck` (entrypoint.sh, test/), `hadolint` (Dockerfile),
`zizmor` (workflow security audit), `entrypoint-tests` (runs `test/entrypoint_tests.sh`).
hadolint: DL3003/DL3008 ignored inline on the wal-g RUN (scoped `cd`; pinning Debian package
versions breaks on every point release). shellcheck: fix the pre-existing SC2034 in
`test/entrypoint_tests.sh`.
zizmor config (`.github/zizmor.yml`) sets `unpinned-uses` policy to accept ref pins
(`@vN`) so it matches the pinning preference; all other findings must be fixed or
individually justified inline.

### Hardening applied to all workflows

- Top-level `permissions: {}`; each job declares only what it needs.
- `actions/checkout` with `persist-credentials: false`.
- `concurrency` group per workflow + ref (`cancel-in-progress` only for PRs, never for publish).
- No `${{ }}` expansion of untrusted input inside `run:` (already true; zizmor enforces).

## 2. Repo governance & updates

### Rulesets (applied via `gh api`)

- **`main`**: require PR (0 approvals); required checks = `scan` pg14–18, `integration` pg14–18,
  all `lint.yml` jobs; block force-push and deletion; bypass: repository admin role.
- **`v*` tags**: block update and deletion (creation allowed); bypass: repository admin role.

### Settings

- Enable Dependabot **alerts** (not update PRs); Renovate owns updates.
- Enable private vulnerability reporting; add `SECURITY.md`.
- Enable "Allow auto-merge" (needed for Renovate platform automerge).
- Keep secret scanning + push protection on.

### Renovate (`.github/renovate.json5`)

- `minimumReleaseAge: "3 days"` globally.
- Automerge (`platformAutomerge: true`) for `minor`/`patch` of `github-actions` and `wal-g/wal-g`.
- Majors: manual PRs (default).
- New custom manager: `postgres` Docker Hub tags against `LATEST_PG` in `build.yml`,
  stable versions only; `automerge: false`; `prBodyNotes` reminding to add the new major
  to both workflow matrices.

## 3. Postgres majors, docs

- pg19: arrives as the Renovate reminder PR above when upstream publishes `postgres:19`.
- pg14: final upstream release is **2026-11-12** (postgresql.org/support/versioning, checked
  2026-09-28). It stays in the matrix until then; README states "supported majors follow
  upstream"; dropping 14 is a normal manual release after that date. Existing `:14` tags stay
  published (no retention job), they just stop being rebuilt.
- pg19 status 2026-09-28: Beta 4 (2026-09-24); no GA image yet.
- README: new "Verifying images" section — `cosign verify` with
  `--certificate-identity-regexp '^https://github.com/0xFl4g/postgres-wal-g/.github/workflows/build.yml@'`
  and `--certificate-oidc-issuer https://token.actions.githubusercontent.com`; SBOM and
  provenance via `docker buildx imagetools inspect --format`.
- `SECURITY.md`: private reporting link, supported versions (latest release per postgres major).
- CLAUDE.md: gate policy, required-check list, split-job rationale, ruleset bypass.

## Verification

| What | How |
|---|---|
| Lint clean | actionlint, zizmor, hadolint, shellcheck run locally, 0 findings |
| Gate blocks | Grype locally with the gate config: current image → pass; `postgres:14.0` (fixable deb HIGH+) → non-zero; a `v1.0.2` checkout (predates the config) → pass |
| CI | PR checks all green, including the new gate and lint jobs |
| Signing / SBOM | After merge: `cosign verify` on published `:<pg>-edge` succeeds; SBOM + provenance visible via imagetools |
| Settings | Rulesets, auto-merge, private reporting, Dependabot alerts read back via `gh api` |
| Automerge | Config review only — exercised on the next real upstream release |

## Out of scope

Other repos' retention workflows; OpenSSF Scorecard; a scheduled scan of already-published images
(the weekly rebuild re-scans); auto-releasing on dependency bumps.
