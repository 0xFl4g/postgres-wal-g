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
#      contents (trailing newline stripped).
#   2. Hands off to the upstream docker-entrypoint.sh unchanged.
#
# If no _FILE vars are set, the script is a no-op pass-through.
# =============================================================================

set -eu

# Iterate over every exported env var ending in _FILE. Compatible with bash 4+;
# avoids `compgen -e` which requires bash and isn't portable to dash.
while IFS='=' read -r name value; do
    case "$name" in
        *_FILE)
            # Strip the _FILE suffix to get the target var name.
            target="${name%_FILE}"

            # Skip if target is already set (explicit env wins over secret).
            if [ -n "${!target:-}" ]; then
                continue
            fi

            if [ -n "$value" ] && [ -r "$value" ]; then
                # tr strips trailing newlines that text editors love to add.
                export "$target"="$(tr -d '\n' < "$value")"
            fi
            ;;
    esac
done < <(env)

# Hand off to the official postgres entrypoint.
exec docker-entrypoint.sh "$@"
