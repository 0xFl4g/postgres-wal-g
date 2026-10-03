#!/bin/bash
# =============================================================================
# entrypoint.sh test suite
# =============================================================================
# Runs the _FILE unwrapping tests against the REAL upstream postgres image by
# mounting entrypoint.sh into it — no local image build required, and the
# interaction with upstream docker-entrypoint.sh (which hard-errors when both
# POSTGRES_X and POSTGRES_X_FILE are set) is exercised for real.
#
# Usage: test/entrypoint_tests.sh [path-to-entrypoint.sh]
#
# CI runs equivalent checks against the built image in .github/workflows/test.yml.
# =============================================================================
set -u

ENTRYPOINT="${1:-$(cd "$(dirname "$0")/.." && pwd)/entrypoint.sh}"
IMG="${TEST_IMAGE:-postgres:18}"
SECRETS=$(mktemp -d)
trap 'rm -rf "$SECRETS"; docker rm -fv walg-t1 >/dev/null 2>&1' EXIT

printf 'supersecret' > "$SECRETS/pw"
printf 'line1\nline2\n' > "$SECRETS/multi"
# Stand-in for the real wal-g binary: echoes the secret it sees and its args.
# shellcheck disable=SC2016 # the $ refs belong to the generated script
printf '#!/bin/sh\nprintf "%%s|%%s" "$AWS_ACCESS_KEY_ID" "$*"\n' > "$SECRETS/fake-wal-g"
chmod +x "$SECRETS/fake-wal-g"

fail=0

# --- Test 1: POSTGRES_PASSWORD_FILE must boot postgres (upstream file_env
# errors if both POSTGRES_PASSWORD and POSTGRES_PASSWORD_FILE are set) ---
docker rm -fv walg-t1 >/dev/null 2>&1
docker run -d --name walg-t1 \
  -v "$ENTRYPOINT":/usr/local/bin/wrap.sh:ro \
  -v "$SECRETS":/run/secrets:ro \
  -e POSTGRES_PASSWORD_FILE=/run/secrets/pw \
  --entrypoint bash \
  "$IMG" /usr/local/bin/wrap.sh postgres >/dev/null

ready=""
for _ in $(seq 1 30); do
  # Only count the final server: the temporary initdb server logs the same line.
  if docker logs walg-t1 2>&1 | sed -n '/init process complete/,$p' | grep -q 'ready to accept connections'; then
    ready=yes; break
  fi
  if [ "$(docker inspect -f '{{.State.Running}}' walg-t1)" = "false" ]; then
    break
  fi
  sleep 1
done
if [ "$ready" = "yes" ]; then
  echo "PASS: test 1 (POSTGRES_PASSWORD_FILE boots postgres)"
else
  echo "FAIL: test 1 — container did not become ready. Last logs:"
  docker logs walg-t1 2>&1 | tail -5
  fail=1
fi
docker rm -fv walg-t1 >/dev/null 2>&1

# --- Test 2: multi-line secret preserved (internal newlines kept, trailing stripped) ---
got=$(docker run --rm \
  -v "$ENTRYPOINT":/usr/local/bin/wrap.sh:ro \
  -v "$SECRETS":/run/secrets:ro \
  -e MULTI_FILE=/run/secrets/multi \
  --entrypoint bash \
  "$IMG" /usr/local/bin/wrap.sh sh -c 'printf %s "$MULTI"')
want=$(printf 'line1\nline2')
if [ "$got" = "$want" ]; then
  echo "PASS: test 2 (multi-line secret preserved)"
else
  echo "FAIL: test 2 — got $(printf %s "$got" | od -c | head -2 | tr '\n' ' ')"
  fail=1
fi

# --- Test 3: single-line secret unwrapped, explicit env wins over _FILE ---
got=$(docker run --rm \
  -v "$ENTRYPOINT":/usr/local/bin/wrap.sh:ro \
  -v "$SECRETS":/run/secrets:ro \
  -e AWS_ACCESS_KEY_ID_FILE=/run/secrets/pw \
  -e AWS_SECRET_ACCESS_KEY_FILE=/run/secrets/pw \
  -e AWS_SECRET_ACCESS_KEY=explicit-wins \
  --entrypoint bash \
  "$IMG" /usr/local/bin/wrap.sh sh -c 'printf "%s|%s" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY"')
if [ "$got" = "supersecret|explicit-wins" ]; then
  echo "PASS: test 3 (unwrap + explicit-env precedence)"
else
  echo "FAIL: test 3 — got: $got"
  fail=1
fi

# --- Test 4: invoked as `wal-g` (docker exec path, no entrypoint run), the
# wrapper unwraps _FILE secrets and execs wal-g.bin with the original args ---
got=$(docker run --rm \
  -v "$ENTRYPOINT":/usr/local/bin/wal-g:ro \
  -v "$SECRETS/fake-wal-g":/usr/local/bin/wal-g.bin:ro \
  -v "$SECRETS":/run/secrets:ro \
  -e AWS_ACCESS_KEY_ID_FILE=/run/secrets/pw \
  --entrypoint bash \
  "$IMG" /usr/local/bin/wal-g backup-list --detail)
if [ "$got" = "supersecret|backup-list --detail" ]; then
  echo "PASS: test 4 (wal-g wrapper sees _FILE secrets)"
else
  echo "FAIL: test 4 — got: $got"
  fail=1
fi

# --- Test 5: unreadable _FILE path on a non-credential var warns on stderr but
# does not block startup (e.g. LOG_FILE may point at a file that doesn't exist yet) ---
got=$(docker run --rm \
  -e LOG_FILE=/run/secrets/nope \
  -v "$ENTRYPOINT":/usr/local/bin/wrap.sh:ro \
  --entrypoint bash \
  "$IMG" /usr/local/bin/wrap.sh echo started 2>&1)
if printf '%s' "$got" | grep -q 'LOG_FILE' && printf '%s' "$got" | grep -q '^started$'; then
  echo "PASS: test 5 (missing _FILE warns, still starts)"
else
  echo "FAIL: test 5 — got: $got"
  fail=1
fi

# --- Test 6: path-type vars whose consumers read the file themselves are
# left alone (no secret contents copied into the env) ---
got=$(docker run --rm \
  -v "$ENTRYPOINT":/usr/local/bin/wrap.sh:ro \
  -v "$SECRETS":/run/secrets:ro \
  -e AWS_CONFIG_FILE=/run/secrets/pw \
  -e AWS_SHARED_CREDENTIALS_FILE=/run/secrets/pw \
  -e AWS_WEB_IDENTITY_TOKEN_FILE=/run/secrets/pw \
  -e SSL_CERT_FILE=/run/secrets/pw \
  -e WALG_S3_CA_CERT_FILE=/run/secrets/pw \
  --entrypoint bash \
  "$IMG" /usr/local/bin/wrap.sh sh -c 'env | grep -c "^\(AWS_CONFIG\|AWS_SHARED_CREDENTIALS\|AWS_WEB_IDENTITY_TOKEN\|SSL_CERT\|WALG_S3_CA_CERT\)="')
if [ "$got" = "0" ]; then
  echo "PASS: test 6 (path-type _FILE vars untouched)"
else
  echo "FAIL: test 6 — $got path-type var(s) unwrapped"
  fail=1
fi

# --- Test 7: unreadable _FILE on a credential var (AWS_/WALG_/...) fails closed:
# non-zero exit, error names the variable, nothing started — via the entrypoint
# and via the wal-g wrapper ---
out=$(docker run --rm \
  -e AWS_SECRET_ACCESS_KEY_FILE=/run/secrets/nope \
  -v "$ENTRYPOINT":/usr/local/bin/wrap.sh:ro \
  --entrypoint bash \
  "$IMG" /usr/local/bin/wrap.sh echo started 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'AWS_SECRET_ACCESS_KEY_FILE' && ! printf '%s' "$out" | grep -q '^started$'; then
  echo "PASS: test 7a (missing credential _FILE fails closed)"
else
  echo "FAIL: test 7a — rc=$rc out: $out"
  fail=1
fi
out=$(docker run --rm \
  -e WALG_LIBSODIUM_KEY_FILE=/run/secrets/nope \
  -v "$ENTRYPOINT":/usr/local/bin/wal-g:ro \
  -v "$SECRETS/fake-wal-g":/usr/local/bin/wal-g.bin:ro \
  --entrypoint bash \
  "$IMG" /usr/local/bin/wal-g backup-list 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'WALG_LIBSODIUM_KEY_FILE' && ! printf '%s' "$out" | grep -q 'backup-list'; then
  echo "PASS: test 7b (wal-g wrapper fails closed too)"
else
  echo "FAIL: test 7b — rc=$rc out: $out"
  fail=1
fi

exit $fail
