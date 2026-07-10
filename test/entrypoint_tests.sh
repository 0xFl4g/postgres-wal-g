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
trap 'rm -rf "$SECRETS"; docker rm -f walg-t1 >/dev/null 2>&1' EXIT

printf 'supersecret' > "$SECRETS/pw"
printf 'line1\nline2\n' > "$SECRETS/multi"

fail=0

# --- Test 1: POSTGRES_PASSWORD_FILE must boot postgres (upstream file_env
# errors if both POSTGRES_PASSWORD and POSTGRES_PASSWORD_FILE are set) ---
docker rm -f walg-t1 >/dev/null 2>&1
docker run -d --name walg-t1 \
  -v "$ENTRYPOINT":/usr/local/bin/wrap.sh:ro \
  -v "$SECRETS":/run/secrets:ro \
  -e POSTGRES_PASSWORD_FILE=/run/secrets/pw \
  --entrypoint bash \
  "$IMG" /usr/local/bin/wrap.sh postgres >/dev/null

ready=""
for i in $(seq 1 30); do
  if docker logs walg-t1 2>&1 | grep -q 'ready to accept connections'; then
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
docker rm -f walg-t1 >/dev/null 2>&1

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

exit $fail
