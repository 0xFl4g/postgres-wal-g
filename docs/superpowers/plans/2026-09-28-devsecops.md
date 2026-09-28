# DevSecOps Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every published postgres-wal-g image is vulnerability-gated, signed and carries an SBOM + provenance; `main` only receives CI-verified changes; dependencies stay current automatically.

**Architecture:** `build.yml` splits into a read-only `scan` job (build amd64 → Grype report + OS-package gate → smoke) and a `publish` job (multi-arch push with SBOM/provenance → cosign keyless sign) that checks out exactly the scanned commit. A new `lint.yml` runs actionlint, zizmor, hadolint, shellcheck and the entrypoint tests. Repo rulesets make all of these required on `main`; Renovate automerges minor/patch bumps once they pass.

**Tech Stack:** GitHub Actions, Docker Buildx, Grype (`anchore/scan-action@v7`), cosign (`sigstore/cosign-installer@v4`), `github/codeql-action/upload-sarif@v4`, zizmor (`zizmorcore/zizmor-action@v0`), actionlint 1.7.12, hadolint v2.15.1, Renovate 44.

**Spec:** `docs/superpowers/specs/2026-09-28-devsecops-design.md`

## Global Constraints

- Scope: this repo only. Branch: `feat/devsecops`.
- Actions pinned to major tags (`@vN`), never commit digests; no `pinDigests` in Renovate.
- CVE gate: fail only on **fixable HIGH/CRITICAL in OS (deb) packages**; Go-module findings reported, never gating.
- Third-party scanners never run in a job holding `packages: write` or `id-token: write`.
- Top-level `permissions: {}` in every workflow; each job declares only what it needs, with a comment per permission.
- Every `actions/checkout` uses `persist-credentials: false`.
- No path filters on `pull_request` triggers (required checks must always report).
- Commits: no Claude attribution lines. Never push without the user's go-ahead; merges are done by the user.
- zizmor must report 0 findings (default persona) with `.github/zizmor.yml`; actionlint, hadolint, shellcheck must be clean.
- PG14 final upstream release 2026-11-12; PG19 not GA (Beta 4, 2026-09-24).

## Review Focus

1. **Fork pull requests** — their token can't write security events; a SARIF upload must be skipped, not fail the job. (Task 2, Step 6 asserts the condition.)
2. **Scheduled/manual rebuild of an older release tag** that predates these files — the gate config must not be read from the checked-out tree. (Task 2, Step 7 runs the gate against a `v1.0.2` checkout.)
3. **`publish` shipping something other than what was scanned** — it must check out `needs.scan.outputs.sha`, never the moving ref. (Task 2, Step 6 asserts it.)
4. **Required-check names drifting from job names** — a renamed job leaves every PR (and Renovate automerge) waiting forever. (Task 5, Step 4 derives contexts from the PR's real check names.)
5. **Renovate proposing a Postgres beta/RC as a new major** — `postgres:19beta*` exists today and must not trigger a PR. (Task 3, Step 4 dry-run asserts no update.)

---

### Task 1: Lint workflow and workflow hardening

**Files:**
- Create: `.github/workflows/lint.yml`
- Create: `.github/zizmor.yml`
- Modify: `.github/workflows/test.yml` (permissions/concurrency block at lines 14–15, checkout at line 29)
- Modify: `Dockerfile` (the wal-g `RUN` at line 31)
- Modify: `test/entrypoint_tests.sh:40`

**Interfaces:**
- Produces: required-check job names `actionlint`, `zizmor`, `hadolint`, `shellcheck`, `entrypoint-tests` (used by Task 5's ruleset).

- [ ] **Step 1: Run the linters against the current tree to see them fail**

```bash
cd /Users/moody/VSCode/postgres-wal-g
hadolint Dockerfile; echo "hadolint exit=$?"
shellcheck entrypoint.sh test/entrypoint_tests.sh; echo "shellcheck exit=$?"
uvx -q zizmor@1.30.1 --offline .github/workflows; echo "zizmor exit=$?"
```

Expected: hadolint exit 1 (DL3003, DL3008 at line 31); shellcheck exit 1 (SC2034 at test line 40); zizmor non-zero (`unpinned-uses` ×9, `artipacked` ×2).

- [ ] **Step 2: Create `.github/zizmor.yml`**

```yaml
rules:
  unpinned-uses:
    config:
      policies:
        # Actions are pinned to major tags (@vN), not commit digests: owner
        # preference. Supply-chain risk is contained by job-level permissions
        # (scanners never hold push/sign rights) and Renovate's minimumReleaseAge.
        "*": ref-pin
```

- [ ] **Step 3: Create `.github/workflows/lint.yml`**

```yaml
name: lint

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

permissions: {}

concurrency:
  group: lint-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  actionlint:
    name: actionlint
    runs-on: ubuntu-latest
    permissions:
      contents: read # checkout only
    steps:
      - uses: actions/checkout@v7
        with:
          persist-credentials: false
      # The image bundles shellcheck, so run: blocks are checked too.
      - run: docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.12 -color

  zizmor:
    name: zizmor
    runs-on: ubuntu-latest
    permissions:
      contents: read # checkout only
    steps:
      - uses: actions/checkout@v7
        with:
          persist-credentials: false
      # Reads .github/zizmor.yml; fails the job on any finding.
      - uses: zizmorcore/zizmor-action@v0
        with:
          advanced-security: false

  hadolint:
    name: hadolint
    runs-on: ubuntu-latest
    permissions:
      contents: read # checkout only
    steps:
      - uses: actions/checkout@v7
        with:
          persist-credentials: false
      - run: docker run --rm -i hadolint/hadolint:v2.15.1 < Dockerfile

  shellcheck:
    name: shellcheck
    runs-on: ubuntu-latest
    permissions:
      contents: read # checkout only
    steps:
      - uses: actions/checkout@v7
        with:
          persist-credentials: false
      - run: shellcheck entrypoint.sh test/entrypoint_tests.sh

  entrypoint-tests:
    name: entrypoint-tests
    runs-on: ubuntu-latest
    permissions:
      contents: read # checkout only
    steps:
      - uses: actions/checkout@v7
        with:
          persist-credentials: false
      - run: ./test/entrypoint_tests.sh
```

- [ ] **Step 4: Harden `test.yml`**

Replace

```yaml
permissions:
  contents: read
```

with

```yaml
permissions: {}

concurrency:
  group: test-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
```

Under `jobs.integration`, directly after `runs-on: ubuntu-latest`, add:

```yaml
    permissions:
      contents: read # checkout only
```

Replace the first step `      - uses: actions/checkout@v7` with:

```yaml
      - uses: actions/checkout@v7
        with:
          persist-credentials: false
```

- [ ] **Step 5: Dockerfile — justify the two hadolint findings inline**

Directly above `RUN set -eux; \` (line 31) insert:

```dockerfile
# DL3003: the `cd /tmp` is scoped to this RUN. DL3008: pinning Debian package
# versions breaks on every point release; the weekly rebuild keeps them current.
# hadolint ignore=DL3003,DL3008
```

- [ ] **Step 6: Fix pre-existing SC2034 in `test/entrypoint_tests.sh:40`**

Change `for i in $(seq 1 30); do` to `for _ in $(seq 1 30); do`.

- [ ] **Step 7: Run all linters — expect clean**

```bash
hadolint Dockerfile && echo "hadolint clean"
shellcheck entrypoint.sh test/entrypoint_tests.sh && echo "shellcheck clean"
actionlint && echo "actionlint clean"
uvx -q zizmor@1.30.1 --offline .github/workflows 2>&1 | tail -1
./test/entrypoint_tests.sh; echo "suite exit=$?"
```

Expected: three "clean" lines; zizmor reports exactly `1 findings` — `artipacked` in `build.yml` (its checkout is rewritten in Task 2); suite 6/6 PASS, exit 0.

- [ ] **Step 8: Commit**

```bash
git add .github/workflows/lint.yml .github/zizmor.yml .github/workflows/test.yml Dockerfile test/entrypoint_tests.sh
git commit -m "ci: lint workflow (actionlint, zizmor, hadolint, shellcheck, entrypoint tests); harden test.yml"
```

---

### Task 2: Split build.yml into scan (gated) and publish (signed)

**Files:**
- Modify (full replacement): `.github/workflows/build.yml`

**Interfaces:**
- Consumes: nothing from Task 1 beyond the zizmor config.
- Produces: required-check job names `scan pg14` … `scan pg18`; `scan` job outputs `sha`, `walg`; published images signed by identity `https://github.com/0xFl4g/postgres-wal-g/.github/workflows/build.yml@<ref>` with issuer `https://token.actions.githubusercontent.com` (used by Task 4 docs and Task 5 verification).

- [ ] **Step 1: Prove the gate policy locally before wiring it (RED/GREEN on the policy itself)**

```bash
SP=/private/tmp/claude-501/-Users-moody-VSCode-postgres-wal-g/0397946e-569b-443a-8da9-a2dd2bb7970b/scratchpad
printf 'ignore:\n  - package:\n      type: go-module\n' > "$SP/grype-gate.yaml"
docker build -q --build-arg POSTGRES_VERSION=18 -t postgres-wal-g:localtest . >/dev/null
grype postgres-wal-g:localtest --only-fixed --fail-on high -q -o table >/dev/null 2>&1; echo "ungated exit=$?"
grype postgres-wal-g:localtest -c "$SP/grype-gate.yaml" --only-fixed --fail-on high -q >/dev/null 2>&1; echo "gated current exit=$?"
grype postgres:14.0 --platform linux/amd64 -c "$SP/grype-gate.yaml" --only-fixed --fail-on high -q >/dev/null 2>&1; echo "gated old-deb exit=$?"
```

Expected: ungated non-zero (Go findings in `wal-g.bin`), gated current `0`, gated old-deb non-zero. This is the policy the workflow encodes.

- [ ] **Step 2: Replace `.github/workflows/build.yml` with**

```yaml
name: build

# Build matrix: every supported postgres major × the WAL-G version pinned in
# the Dockerfile. Two jobs so third-party scanners never hold push/sign rights:
#   scan    — build amd64, Grype report + gate, smoke test (read-only token)
#   publish — multi-arch push with SBOM + provenance, cosign keyless signing
# Publishes to GHCR:
#   - v* tag push                → :<pg>-<walg>, :<pg>, :latest (newest pg only)
#   - weekly schedule / manual   → same release tags, rebuilt from the newest
#                                  v* tag to pick up upstream postgres minor
#                                  releases and Debian security fixes
#   - push to main               → :<pg>-edge only
#   - pull request               → scan only (plus an arm64 build check)

on:
  push:
    branches: [main]
    tags: ['v*']
  pull_request:
    branches: [main]
  schedule:
    - cron: '0 5 * * 1'
  workflow_dispatch:

permissions: {}

concurrency:
  group: build-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

env:
  REGISTRY: ghcr.io
  # Newest postgres major in the matrix below — gets the :latest tag.
  # Bump together with the matrix when a new major lands.
  LATEST_PG: '18'

jobs:
  scan:
    name: scan pg${{ matrix.postgres }}
    runs-on: ubuntu-latest
    permissions:
      contents: read # checkout
      security-events: write # upload Grype SARIF to code scanning
    outputs:
      sha: ${{ steps.src.outputs.sha }}
      walg: ${{ steps.walg.outputs.version }}
    strategy:
      fail-fast: false
      matrix:
        postgres: ['14', '15', '16', '17', '18']
    steps:
      - uses: actions/checkout@v7
        with:
          # Rebuilds need the tag list to find the newest release.
          fetch-depth: 0
          persist-credentials: false

      - name: Check out newest release (scheduled/manual rebuild)
        if: github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'
        run: git checkout "$(git tag -l 'v*' --sort=-v:refname | head -n1)"

      - name: Record source commit
        id: src
        # publish checks out exactly this commit, so it ships what was scanned.
        run: echo "sha=$(git rev-parse HEAD)" >> "$GITHUB_OUTPUT"

      - name: Resolve WAL-G version
        id: walg
        run: |
          # The Dockerfile ARG is the single source of truth, so a rebuild of
          # an old release tag uses that release's WAL-G version.
          version="$(sed -n 's/^ARG WAL_G_VERSION=//p' Dockerfile)"
          if ! printf '%s' "$version" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
            echo "Could not parse WAL-G version from Dockerfile: '$version'" >&2
            exit 1
          fi
          echo "version=$version" >> "$GITHUB_OUTPUT"

      - name: Set up QEMU (PR arm64 check)
        if: github.event_name == 'pull_request'
        uses: docker/setup-qemu-action@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v4

      - name: Build amd64
        uses: docker/build-push-action@v7
        with:
          context: .
          platforms: linux/amd64
          load: true
          tags: postgres-wal-g:scan
          build-args: POSTGRES_VERSION=${{ matrix.postgres }}
          cache-from: type=gha,scope=pg${{ matrix.postgres }}
          cache-to: type=gha,mode=max,scope=pg${{ matrix.postgres }}

      - name: Vulnerability report (all findings)
        id: report
        uses: anchore/scan-action@v7
        with:
          image: postgres-wal-g:scan
          fail-build: false
          output-format: sarif

      - name: Upload report to code scanning
        # Fork PRs get a read-only token that can't write security events.
        if: github.event.pull_request.head.repo.fork != true
        uses: github/codeql-action/upload-sarif@v4
        with:
          sarif_file: ${{ steps.report.outputs.sarif }}
          category: grype-pg${{ matrix.postgres }}

      - name: Write gate config
        run: |
          # Gate only OS packages: CVEs in bundled Go binaries (wal-g, gosu) are
          # only fixable upstream and are reported above instead. Written here,
          # not read from the repo, because scheduled rebuilds check out older
          # release tags that don't contain it.
          cat > "$RUNNER_TEMP/grype-gate.yaml" <<'YAML'
          ignore:
            - package:
                type: go-module
          YAML

      - name: Vulnerability gate (fixable HIGH+ in OS packages)
        uses: anchore/scan-action@v7
        with:
          image: postgres-wal-g:scan
          config: ${{ runner.temp }}/grype-gate.yaml
          only-fixed: true
          severity-cutoff: high
          fail-build: true
          output-format: table

      - name: Smoke test
        run: |
          # Goes through the /usr/local/bin/wal-g wrapper symlink.
          docker run --rm --entrypoint wal-g postgres-wal-g:scan --version
          docker run --rm --entrypoint postgres postgres-wal-g:scan --version

      - name: Build arm64 (PR check, not pushed)
        if: github.event_name == 'pull_request'
        uses: docker/build-push-action@v7
        with:
          context: .
          platforms: linux/arm64
          build-args: POSTGRES_VERSION=${{ matrix.postgres }}
          cache-from: type=gha,scope=pg${{ matrix.postgres }}

  publish:
    name: publish pg${{ matrix.postgres }}
    # Needs the whole scan matrix: one major failing the gate blocks
    # publishing for all majors in this run.
    needs: scan
    if: github.event_name != 'pull_request'
    runs-on: ubuntu-latest
    permissions:
      contents: read # checkout
      packages: write # push to GHCR
      id-token: write # cosign keyless signing (OIDC)
    strategy:
      fail-fast: false
      matrix:
        postgres: ['14', '15', '16', '17', '18']
    steps:
      - uses: actions/checkout@v7
        with:
          ref: ${{ needs.scan.outputs.sha }}
          persist-credentials: false

      - name: Resolve image name (lowercase)
        id: image
        env:
          OWNER_REPO: ${{ github.repository }}
        run: |
          # Docker registries reject mixed-case repository names. Lowercase
          # the full owner/repo path here so :tag composition is safe later.
          lower="$(printf '%s' "$OWNER_REPO" | tr '[:upper:]' '[:lower:]')"
          echo "name=$lower" >> "$GITHUB_OUTPUT"

      - name: Compute tags
        id: tags
        env:
          PG: ${{ matrix.postgres }}
          WALG: ${{ needs.scan.outputs.walg }}
          EVENT: ${{ github.event_name }}
          REF: ${{ github.ref }}
          IMAGE: ${{ steps.image.outputs.name }}
        run: |
          image="${REGISTRY}/${IMAGE}"
          tags=""
          case "$EVENT:$REF" in
            push:refs/tags/v*|schedule:*|workflow_dispatch:*)
              tags="${image}:${PG}-${WALG},${image}:${PG}"
              if [ "$PG" = "$LATEST_PG" ]; then
                tags="${tags},${image}:latest"
              fi
              ;;
            push:refs/heads/main)
              tags="${image}:${PG}-edge"
              ;;
          esac
          echo "tags=$tags" >> "$GITHUB_OUTPUT"

      - name: Set up QEMU
        uses: docker/setup-qemu-action@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v4

      - name: Log in to GHCR
        uses: docker/login-action@v4
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push
        id: push
        uses: docker/build-push-action@v7
        with:
          context: .
          platforms: linux/amd64,linux/arm64
          push: true
          tags: ${{ steps.tags.outputs.tags }}
          build-args: POSTGRES_VERSION=${{ matrix.postgres }}
          sbom: true
          provenance: mode=max
          cache-from: type=gha,scope=pg${{ matrix.postgres }}
          cache-to: type=gha,mode=max,scope=pg${{ matrix.postgres }}

      - uses: sigstore/cosign-installer@v4

      - name: Sign image (cosign keyless)
        env:
          IMAGE: ${{ steps.image.outputs.name }}
          DIGEST: ${{ steps.push.outputs.digest }}
        # Signs the digest, so every tag pointing at it is covered.
        run: cosign sign --yes "${REGISTRY}/${IMAGE}@${DIGEST}"
```

- [ ] **Step 3: Lint**

```bash
actionlint && echo "actionlint clean"
uvx -q zizmor@1.30.1 --offline .github/workflows 2>&1 | tail -1
uvx -q zizmor@1.30.1 --offline --persona=auditor .github/workflows/build.yml .github/workflows/lint.yml 2>&1 | tail -1
```

Expected: `actionlint clean`; both zizmor runs `No findings to report. Good job!`

- [ ] **Step 4: Tag logic unchanged — run the Compute tags step for every event**

```bash
uv run -q --with pyyaml python - <<'EOF'
import yaml, subprocess, os
wf = yaml.safe_load(open('.github/workflows/build.yml'))
run = [s for s in wf['jobs']['publish']['steps'] if s.get('id') == 'tags'][0]['run']
cases = [('push','refs/tags/v1.0.3','18'), ('push','refs/tags/v1.0.3','16'), ('schedule','refs/heads/main','18'),
         ('workflow_dispatch','refs/heads/main','17'), ('push','refs/heads/main','18')]
want = {
 0: 'tags=ghcr.io/o/r:18-v3.0.9,ghcr.io/o/r:18,ghcr.io/o/r:latest',
 1: 'tags=ghcr.io/o/r:16-v3.0.9,ghcr.io/o/r:16',
 2: 'tags=ghcr.io/o/r:18-v3.0.9,ghcr.io/o/r:18,ghcr.io/o/r:latest',
 3: 'tags=ghcr.io/o/r:17-v3.0.9,ghcr.io/o/r:17',
 4: 'tags=ghcr.io/o/r:18-edge',
}
for i, (ev, ref, pg) in enumerate(cases):
    env = dict(os.environ, REGISTRY='ghcr.io', LATEST_PG='18', PG=pg, WALG='v3.0.9', EVENT=ev, REF=ref, IMAGE='o/r', GITHUB_OUTPUT='/dev/stdout')
    out = subprocess.run(['bash','-eo','pipefail','-c',run], env=env, capture_output=True, text=True).stdout.strip()
    assert out == want[i], (ev, ref, pg, out)
print("tag logic OK (5 cases)")
EOF
```

Expected: `tag logic OK (5 cases)`

- [ ] **Step 5: `publish` never runs on pull requests and holds the only write permissions**

```bash
uv run -q --with pyyaml python - <<'EOF'
import yaml
wf = yaml.safe_load(open('.github/workflows/build.yml'))
assert wf['permissions'] == {}, wf['permissions']
scan, pub = wf['jobs']['scan'], wf['jobs']['publish']
assert set(scan['permissions']) == {'contents', 'security-events'}, scan['permissions']
assert scan['permissions']['contents'] == 'read'
assert pub['if'] == "github.event_name != 'pull_request'"
assert pub['needs'] == 'scan'
third_party = [s['uses'] for s in pub['steps'] if 'uses' in s and not s['uses'].split('/')[0] in ('actions','docker','sigstore')]
assert third_party == [], third_party
print("permission split OK")
EOF
```

Expected: `permission split OK`

- [ ] **Step 6: Review-focus assertions (fork PRs, scanned commit = published commit)**

```bash
uv run -q --with pyyaml python - <<'EOF'
import yaml
wf = yaml.safe_load(open('.github/workflows/build.yml'))
up = [s for s in wf['jobs']['scan']['steps'] if s.get('uses','').startswith('github/codeql-action/upload-sarif')][0]
assert up['if'] == 'github.event.pull_request.head.repo.fork != true', up.get('if')
co = wf['jobs']['publish']['steps'][0]
assert co['uses'].startswith('actions/checkout') and co['with']['ref'] == '${{ needs.scan.outputs.sha }}', co
for job in wf['jobs'].values():
    for s in job['steps']:
        if s.get('uses','').startswith('actions/checkout'):
            assert s['with']['persist-credentials'] is False, s
print("review-focus assertions OK")
EOF
```

Expected: `review-focus assertions OK`

- [ ] **Step 7: Gate works when a scheduled rebuild checks out an older release (v1.0.2 predates these files)**

```bash
SP=/private/tmp/claude-501/-Users-moody-VSCode-postgres-wal-g/0397946e-569b-443a-8da9-a2dd2bb7970b/scratchpad
rm -rf "$SP/wt-v102"; git worktree add -q "$SP/wt-v102" v1.0.2
test ! -e "$SP/wt-v102/.github/grype-gate.yaml" && echo "v1.0.2 has no gate config file (as expected)"
RUNNER_TEMP="$SP/rt"; mkdir -p "$RUNNER_TEMP"
# Execute the workflow's own "Write gate config" step body, from the v1.0.2 checkout.
uv run -q --with pyyaml python -c "import yaml;print([s for s in yaml.safe_load(open('.github/workflows/build.yml'))['jobs']['scan']['steps'] if s.get('name')=='Write gate config'][0]['run'])" > "$SP/write-gate.sh"
(cd "$SP/wt-v102" && RUNNER_TEMP="$RUNNER_TEMP" bash -eo pipefail "$SP/write-gate.sh")
docker build -q --build-arg POSTGRES_VERSION=18 -t postgres-wal-g:v102 "$SP/wt-v102" >/dev/null
grype postgres-wal-g:v102 -c "$RUNNER_TEMP/grype-gate.yaml" --only-fixed --fail-on high -q >/dev/null 2>&1; echo "gate on v1.0.2 exit=$?"
git worktree remove --force "$SP/wt-v102"; docker rmi -f postgres-wal-g:v102 >/dev/null
```

Expected: the "as expected" line, then `gate on v1.0.2 exit=0`.

- [ ] **Step 8: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "ci(build): split into read-only scan (Grype gate + SARIF) and publish (SBOM, provenance, cosign)"
```

---

### Task 3: Renovate — release-age buffer, automerge, postgres majors, workflow images

**Files:**
- Modify (full replacement): `.github/renovate.json5`

**Interfaces:**
- Consumes: `LATEST_PG: '18'` in `build.yml` (Task 2); image refs `rhysd/actionlint:1.7.12`, `hadolint/hadolint:v2.15.1` (Task 1), `versity/versitygw:v1.8.0` (existing `test.yml`).
- Produces: nothing code-level.

- [ ] **Step 1: Validate the current config strictly — expect a migration failure**

```bash
docker run --rm --tmpfs /tmp:size=512m -v "$PWD:/usr/src/app" -w /usr/src/app renovate/renovate:44 renovate-config-validator --strict 2>&1 | grep -E 'WARN|INFO' | head -3
```

Expected: `WARN: Config migration necessary` (`fileMatch` → `managerFilePatterns`).

- [ ] **Step 2: Replace `.github/renovate.json5` with**

```json5
{
  $schema: "https://docs.renovatebot.com/renovate-schema.json",
  extends: [
    "config:recommended",
    ":semanticCommits",
  ],
  // Supply-chain buffer: don't propose a release until it is 3 days old.
  // Compromised releases are usually caught and yanked within hours.
  minimumReleaseAge: "3 days",
  // The dockerfile manager resolves `FROM postgres:${POSTGRES_VERSION}` via
  // the ARG default (18). It only ever proposes a major bump, which lands in
  // the same `postgres` PR as LATEST_PG below. Postgres minor and Debian
  // security updates arrive via build.yml's weekly rebuild instead.
  //
  // Renovate also watches WAL-G upstream and bumps every WAL-G version
  // site in lockstep: the Dockerfile ARG (single source of truth — build.yml
  // and test.yml build from it) plus the README / Dockerfile-comment examples,
  // including `18-v3.0.9`-style image tags. Upstream has renamed release
  // assets before (v3.0.8 dropped `ubuntu-`), so a failing build on a bump
  // PR usually means the URL in the Dockerfile needs updating.
  customManagers: [
    {
      customType: "regex",
      managerFilePatterns: [
        "/^Dockerfile$/",
        "/^README\\.md$/",
      ],
      matchStrings: [
        // `ARG WAL_G_VERSION=v3.0.9`, `--build-arg WAL_G_VERSION=v3.0.9`
        "WAL_G_VERSION=(?<currentValue>v[0-9.]+)",
        // image tag examples: `18-v3.0.9`
        "\\b[0-9]{2}-(?<currentValue>v[0-9]+\\.[0-9]+\\.[0-9]+)\\b",
      ],
      depNameTemplate: "wal-g/wal-g",
      datasourceTemplate: "github-releases",
      extractVersionTemplate: "^(?<version>v[0-9.]+)$",
    },
    {
      // New postgres major: bump LATEST_PG once upstream publishes the image.
      // Pure-major tags only ("19"), so betas and RCs never match.
      customType: "regex",
      managerFilePatterns: ["/^\\.github/workflows/build\\.yml$/"],
      matchStrings: ["LATEST_PG: '(?<currentValue>[0-9]+)'"],
      depNameTemplate: "postgres",
      datasourceTemplate: "docker",
      versioningTemplate: "regex:^(?<major>\\d+)$",
    },
    {
      // Container images run from workflow `run:` blocks (lint tools, test S3).
      customType: "regex",
      managerFilePatterns: ["/^\\.github/workflows/[^/]+\\.yml$/"],
      matchStrings: [
        "(?<depName>rhysd/actionlint|hadolint/hadolint|versity/versitygw):(?<currentValue>v?[0-9]+\\.[0-9]+\\.[0-9]+)",
      ],
      datasourceTemplate: "docker",
    },
  ],
  packageRules: [
    // Group GH-Action bumps together — they fire often. Actions are
    // pinned to major tags (@vN), not digests, matching the org-wide
    // style; Renovate bumps the major when a new one is released.
    {
      matchManagers: ["github-actions"],
      groupName: "github-actions",
    },
    // Minor/patch bumps merge themselves once every required check passes
    // (scan gate, integration restore test, lint). Actions pinned @vN only
    // ever get major bumps, so in practice this is WAL-G and the images above.
    {
      matchUpdateTypes: ["minor", "patch"],
      automerge: true,
    },
    {
      matchDepNames: ["postgres"],
      automerge: false,
      prBodyNotes: [
        "New postgres major: also add it to the matrix in `build.yml` and `test.yml`, then tag a release.",
      ],
    },
  ],
  prConcurrentLimit: 3,
}
```

- [ ] **Step 3: Validate strictly — expect success**

```bash
docker run --rm --tmpfs /tmp:size=512m -v "$PWD:/usr/src/app" -w /usr/src/app renovate/renovate:44 renovate-config-validator --strict 2>&1 | tail -1
```

Expected: `INFO: Config validated successfully against 1 file(s)`

- [ ] **Step 4: Lookup dry-run — every manager extracts, no beta postgres proposed**

Local mode reads committed files, so commit first, then run:

```bash
SP=/private/tmp/claude-501/-Users-moody-VSCode-postgres-wal-g/0397946e-569b-443a-8da9-a2dd2bb7970b/scratchpad
git add .github/renovate.json5 && git commit -m "chore(renovate): 3-day release age, automerge minor/patch, track postgres majors + workflow images"
docker run --rm --tmpfs /tmp:size=1g -e LOG_LEVEL=debug -v "$PWD:/usr/src/app" -w /usr/src/app renovate/renovate:44 \
  renovate --platform=local --dry-run=lookup --onboarding=false > $SP/renovate-lookup.log 2>&1; echo "exit=$?"
for d in 'wal-g/wal-g' 'rhysd/actionlint' 'hadolint/hadolint' 'versity/versitygw'; do grep -q "\"depName\": \"$d\"" $SP/renovate-lookup.log && echo "extracted $d"; done
sed -n '/packageFiles with updates/,/Repository timing/p' $SP/renovate-lookup.log | grep -A6 '"depName": "postgres"' | grep -E '"currentValue": "18"' >/dev/null && echo "extracted postgres 18"
sed -n '/packageFiles with updates/,/Repository timing/p' $SP/renovate-lookup.log | grep -A12 '"depName": "postgres"' | grep -E '"newValue": "19(beta|rc)' && echo "FAIL: beta proposed" || echo "no beta/rc proposed"
```

Expected: `exit=0`, five `extracted …` lines, `no beta/rc proposed`. (The commit in this step is the task's commit.)

---

### Task 4: Documentation

**Files:**
- Create: `SECURITY.md`
- Modify: `README.md` (after the "Supported postgres majors" line; new section before "## Quickstart")
- Modify: `CLAUDE.md` (Testing section; new "Supply chain & CI" section before "## Releases")

**Interfaces:**
- Consumes: signing identity + issuer from Task 2; required-check names from Tasks 1–2.

- [ ] **Step 1: Create `SECURITY.md`**

```markdown
# Security policy

## Reporting a vulnerability

Report privately through GitHub: **Security → Report a vulnerability** on this repository
(https://github.com/0xFl4g/postgres-wal-g/security/advisories/new). Please don't open a public issue.

In scope: this repo's entrypoint, Dockerfile and CI. Vulnerabilities in PostgreSQL, WAL-G or the
Debian base image belong upstream; the weekly rebuild picks up their fixes.

## Supported versions

The latest release, for each postgres major in the build matrix (currently 14–18). 14 is supported
until its final upstream release on 2026-11-12.

## What CI enforces

- Every image is scanned with Grype before it is published. Fixable HIGH/CRITICAL CVEs in OS
  packages block publishing. All findings, including those in the bundled WAL-G binary (only
  fixable upstream), are reported in the repository's Security tab.
- Published images are signed with cosign (keyless) and carry an SBOM and build provenance.
  See "Verifying images" in the README.
```

- [ ] **Step 2: README — supported majors policy**

Replace the line

```markdown
Supported postgres majors: 14, 15, 16, 17, 18. Multi-arch: `linux/amd64`, `linux/arm64`.
```

with

```markdown
Supported postgres majors: 14, 15, 16, 17, 18. Multi-arch: `linux/amd64`, `linux/arm64`. Majors follow upstream support: 14 is dropped after its final upstream release (2026-11-12); a new major is added once upstream publishes its image.
```

- [ ] **Step 3: README — "Verifying images" section, inserted directly before `## Quickstart`**

```markdown
## Verifying images

Every published image is signed with [cosign](https://github.com/sigstore/cosign) keyless signing from this repo's `build.yml`, and carries an SBOM and build provenance.

```bash
cosign verify ghcr.io/0xfl4g/postgres-wal-g:18 \
  --certificate-identity-regexp '^https://github.com/0xFl4g/postgres-wal-g/\.github/workflows/build\.yml@' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

# SBOM (SPDX) and provenance, attached by BuildKit
docker buildx imagetools inspect ghcr.io/0xfl4g/postgres-wal-g:18 --format '{{ json .SBOM }}'
docker buildx imagetools inspect ghcr.io/0xfl4g/postgres-wal-g:18 --format '{{ json .Provenance }}'
```

Images are scanned with Grype before publishing; fixable HIGH/CRITICAL CVEs in OS packages block the release. Findings in the bundled WAL-G binary are only fixable upstream, so they are reported (Security tab) but don't block. See [SECURITY.md](./SECURITY.md).
```

- [ ] **Step 4: CLAUDE.md — lint commands in "## Testing"**

Append inside the existing ```bash block in "## Testing", after the `docker build` line:

```bash
# Lint (same as lint.yml)
actionlint && shellcheck entrypoint.sh test/entrypoint_tests.sh && hadolint Dockerfile
uvx zizmor .github/workflows
```

- [ ] **Step 5: CLAUDE.md — new section directly before "## Releases"**

```markdown
## Supply chain & CI

- `build.yml` = `scan` (read-only token: build amd64, Grype report → SARIF, Grype gate, smoke)
  → `publish` (push + SBOM + provenance, cosign keyless sign). Never add a third-party action to
  `publish`; it holds `packages: write` and `id-token: write`. `publish` checks out
  `needs.scan.outputs.sha` so it ships exactly what was scanned.
- Gate = fixable HIGH/CRITICAL in **deb** packages only. Go-module findings (wal-g, gosu) are only
  fixable upstream: reported, not gating. The gate config is written inline to `$RUNNER_TEMP`
  because scheduled rebuilds check out older tags that don't have repo files added later.
- Ruleset on `main`: PR + 15 required checks (`scan pg14–18`, `integration (pg14–18)`, `actionlint`,
  `zizmor`, `hadolint`, `shellcheck`, `entrypoint-tests`); admin bypass. **Renaming a job means
  updating the ruleset**, or every PR (and Renovate automerge) waits forever. No path filters on
  `pull_request`. Ruleset on `v*` tags: no update/delete.
- zizmor's `unpinned-uses` accepts `@vN` via `.github/zizmor.yml`. Renovate: `minimumReleaseAge`
  3 days, automerge minor/patch, postgres majors arrive as a manual PR (pure-major tags only).
- PG14 final upstream release 2026-11-12: drop it from both matrices in the next release after.
```

- [ ] **Step 6: Verify docs render the right identity and nothing drifted**

```bash
grep -cF "certificate-identity-regexp '^https://github.com/0xFl4g/postgres-wal-g/\.github/workflows/build\.yml@'" README.md
grep -n "2026-11-12" README.md SECURITY.md CLAUDE.md | wc -l
wc -l CLAUDE.md
```

Expected: `1`; `3`; CLAUDE.md under 200 lines.

- [ ] **Step 7: Commit**

```bash
git add SECURITY.md README.md CLAUDE.md
git commit -m "docs: security policy, image verification, supply-chain notes"
```

---

### Task 5: Ship — PR, merge, repo settings, rulesets, live verification

**Files:** none (GitHub API + registry).

**Interfaces:**
- Consumes: job names from Tasks 1–2; signing identity from Task 2.

- [ ] **Step 1: Push branch and open PR** (user has approved pushing this work)

```bash
git push -u origin feat/devsecops
gh pr create --base main --head feat/devsecops --title "DevSecOps: Grype gate, cosign signing, SBOM/provenance, lint, Renovate automerge" \
  --body "Implements docs/superpowers/specs/2026-09-28-devsecops-design.md. Plan: docs/superpowers/plans/2026-09-28-devsecops.md."
```

- [ ] **Step 2: Wait for checks; all must pass**

```bash
gh pr checks --watch --interval 30 >/dev/null 2>&1; gh pr checks | awk -F'\t' '{print $1"\t"$2}'
```

Expected: `pass` for `scan pg14`…`scan pg18`, `integration (pg14)`…`(pg18)`, `actionlint`, `zizmor`, `hadolint`, `shellcheck`, `entrypoint-tests`, and the five `Upload report` SARIF results visible under the PR's Security/code-scanning section. `publish` shows as one skipped check (`publish pg${{ matrix.postgres }}`) — a job-level `if:` skips the matrix before it expands.

- [ ] **Step 3: User merges** — ask the user to run `! gh pr merge <N> --rebase --delete-branch`. Then:

```bash
git switch main && git pull --ff-only origin main
```

- [ ] **Step 4: Apply repo settings and rulesets**

```bash
R=0xFl4g/postgres-wal-g
gh api -X PATCH repos/$R -F allow_auto_merge=true --jq .allow_auto_merge
gh api -X PUT repos/$R/vulnerability-alerts --silent && echo "dependabot alerts on"
gh api -X PUT repos/$R/private-vulnerability-reporting --silent && echo "private reporting on"

# Required-check contexts come from the merged PR's real check names (Review Focus 4).
PR=$(gh pr list --state merged --head feat/devsecops --json number --jq '.[0].number')
SHA=$(gh pr view $PR --json headRefOid --jq .headRefOid)
APP_ID=$(gh api repos/$R/commits/$SHA/check-runs --jq '[.check_runs[] | select(.app.slug=="github-actions")][0].app.id')
CONTEXTS=$(gh api repos/$R/commits/$SHA/check-runs --paginate --jq '.check_runs[] | select(.app.slug=="github-actions") | .name' \
  | grep -E '^(scan pg1[4-8]|integration \(pg1[4-8]\)|actionlint|zizmor|hadolint|shellcheck|entrypoint-tests)$' | sort -u)
echo "$CONTEXTS" | wc -l   # expect 15

jq -n --argjson app "$APP_ID" --arg ctx "$CONTEXTS" '{
  name: "main", target: "branch", enforcement: "active",
  conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
  bypass_actors: [{actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "always"}],
  rules: [
    {type: "deletion"}, {type: "non_fast_forward"},
    {type: "pull_request", parameters: {required_approving_review_count: 0, dismiss_stale_reviews_on_push: false,
      require_code_owner_review: false, require_last_push_approval: false, required_review_thread_resolution: false,
      allowed_merge_methods: ["merge", "squash", "rebase"]}},
    {type: "required_status_checks", parameters: {strict_required_status_checks_policy: false,
      required_status_checks: ($ctx | split("\n") | map(select(length > 0)) | map({context: ., integration_id: $app}))}}
  ]}' | gh api -X POST repos/$R/rulesets --input - --jq '.id'

jq -n '{
  name: "release-tags", target: "tag", enforcement: "active",
  conditions: {ref_name: {include: ["refs/tags/v*"], exclude: []}},
  bypass_actors: [{actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "always"}],
  rules: [{type: "deletion"}, {type: "update"}]
}' | gh api -X POST repos/$R/rulesets --input - --jq '.id'
```

Expected: `true`, two "on" lines, `15`, two ruleset ids.

- [ ] **Step 5: Read everything back**

```bash
R=0xFl4g/postgres-wal-g
gh api repos/$R --jq '"auto_merge=\(.allow_auto_merge)"'
gh api repos/$R/vulnerability-alerts --silent && echo "dependabot alerts: enabled"
gh api repos/$R/private-vulnerability-reporting --jq '"private reporting: \(.enabled)"'
for id in $(gh api repos/$R/rulesets --jq '.[].id'); do gh api repos/$R/rulesets/$id --jq '"\(.name) \(.target) \(.enforcement) rules=\([.rules[].type]|join(",")) checks=\([.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks[]]|length)"'; done
```

Expected: `auto_merge=true`, alerts enabled, `private reporting: true`, `main branch active rules=deletion,non_fast_forward,pull_request,required_status_checks checks=15`, `release-tags tag active rules=deletion,update checks=0`.

- [ ] **Step 6: Post-merge `main` build publishes signed edge images**

```bash
id=$(gh run list --workflow build --branch main --event push --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch $id --interval 30 --exit-status >/dev/null; echo "build exit=$?"
cosign verify ghcr.io/0xfl4g/postgres-wal-g:18-edge \
  --certificate-identity-regexp '^https://github.com/0xFl4g/postgres-wal-g/\.github/workflows/build\.yml@' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com >/dev/null && echo "cosign verify OK"
docker buildx imagetools inspect ghcr.io/0xfl4g/postgres-wal-g:18-edge --format '{{ json .SBOM }}' | head -c 120; echo
docker buildx imagetools inspect ghcr.io/0xfl4g/postgres-wal-g:18-edge --format '{{ json .Provenance }}' | head -c 120; echo
```

Expected: `build exit=0`, `cosign verify OK`, non-empty SBOM and Provenance JSON prefixes.

- [ ] **Step 7: Sign + attest the current release tags now** (instead of waiting for Monday's rebuild): ask the user before running, since it republishes `:14`–`:18`/`:latest` from `v1.0.2`.

```bash
gh workflow run build.yml --ref main
sleep 10; id=$(gh run list --workflow build --event workflow_dispatch --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch $id --interval 30 --exit-status >/dev/null; echo "dispatch build exit=$?"
cosign verify ghcr.io/0xfl4g/postgres-wal-g:18 \
  --certificate-identity-regexp '^https://github.com/0xFl4g/postgres-wal-g/\.github/workflows/build\.yml@' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com >/dev/null && echo "release :18 signed"
```

Expected: `dispatch build exit=0`, `release :18 signed`.
