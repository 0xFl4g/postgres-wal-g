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
#      An unreadable path is reported on stderr; for credential vars (AWS_*,
#      WALG_*, WALE_*, GS_*, AZURE_*, SWIFT_*, OS_*) it is fatal (exit 1) so
#      the container never starts with a silently missing secret. Other names
#      (e.g. LOG_FILE) only warn and are skipped.
#   2. Hands off to the upstream docker-entrypoint.sh unchanged — or, when
#      invoked as `wal-g` (/usr/local/bin/wal-g is a symlink to this script),
#      to the real binary. That second path is what makes `docker exec … wal-g`
#      see the secrets: exec'd processes never pass through the entrypoint.
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
        # Standard path settings whose consumers (AWS SDK, Go TLS, WAL-G) read
        # the file themselves. Unwrapping would only copy secrets into env.
        AWS_CONFIG_FILE|AWS_SHARED_CREDENTIALS_FILE|AWS_WEB_IDENTITY_TOKEN_FILE|SSL_CERT_FILE|WALG_S3_CA_CERT_FILE) ;;
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
            else
                echo "postgres-wal-g: $name=$value is not readable; $target left unset" >&2
                # Credential vars fail closed; arbitrary *_FILE (e.g. LOG_FILE) only warn.
                case "$name" in
                    AWS_*|WALG_*|WALE_*|GS_*|AZURE_*|SWIFT_*|OS_*) exit 1 ;;
                esac
            fi
            ;;
    esac
done < <(env -0)

if [ "${0##*/}" = wal-g ]; then
    exec /usr/local/bin/wal-g.bin "$@"
fi

# Hand off to the official postgres entrypoint.
exec docker-entrypoint.sh "$@"
