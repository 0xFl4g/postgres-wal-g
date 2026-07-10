#!/bin/bash
# =============================================================================
# postgres-wal-g entrypoint wrapper
# =============================================================================
# Generalises the `*_FILE` Docker-secret convention to arbitrary env vars that
# WAL-G expects (AWS_*, WALG_*, GS_*, AZURE_*, etc.). The official postgres
# image only resolves POSTGRES_*_FILE — anything else is ignored, which makes
# Docker secrets unergonomic for WAL-G.
#
# This wrapper:
#   1. For every env var ending in _FILE whose value points at a readable file,
#      exports a same-named var (without the _FILE suffix) with the file's
#      contents (trailing newlines stripped, internal newlines preserved).
#   2. Hands off to the upstream docker-entrypoint.sh unchanged.
#
# POSTGRES_*_FILE vars are left untouched: the upstream entrypoint resolves
# those itself and hard-errors if both VAR and VAR_FILE are set, so unwrapping
# them here would break container startup.
#
# If no _FILE vars are set, the script is a no-op pass-through.
# =============================================================================

set -eu

# Iterate over the environment null-delimited so values containing newlines
# can't be misparsed as separate vars. bash-only, like the rest of this script.
while IFS= read -r -d '' entry; do
    name="${entry%%=*}"
    value="${entry#*=}"
    case "$name" in
        # Upstream docker-entrypoint.sh owns the POSTGRES_* namespace.
        POSTGRES_*) ;;
        ?*_FILE)
            # Strip the _FILE suffix to get the target var name.
            target="${name%_FILE}"

            # Skip if target is already set (explicit env wins over secret).
            if [ -n "${!target:-}" ]; then
                continue
            fi

            if [ -n "$value" ] && [ -r "$value" ]; then
                # $(< file) strips trailing newlines only. Internal newlines
                # (PEM/PGP keys, JSON creds) must survive intact.
                export "$target"="$(< "$value")"
            fi
            ;;
    esac
done < <(env -0)

# Hand off to the official postgres entrypoint.
exec docker-entrypoint.sh "$@"
