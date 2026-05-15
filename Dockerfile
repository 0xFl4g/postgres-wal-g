# =============================================================================
# postgres + WAL-G — combined image for continuous WAL archiving and PITR
# =============================================================================
# A drop-in replacement for the official `postgres` image with WAL-G baked in
# and a Docker-secrets-friendly entrypoint that resolves *_FILE env vars
# before handing off to the upstream docker-entrypoint.sh.
#
# WAL-G is dormant until your postgresql.conf flips `archive_mode = on` plus
# `archive_command = '/usr/local/bin/wal-g wal-push %p'`. The image adds no
# runtime overhead until activated.
#
# Build:
#   docker build \
#     --build-arg POSTGRES_VERSION=18 \
#     --build-arg WAL_G_VERSION=v3.0.5 \
#     -t ghcr.io/0xfl4g/postgres-wal-g:18-v3.0.5 .
# =============================================================================

ARG POSTGRES_VERSION=18

FROM postgres:${POSTGRES_VERSION}

# WAL-G version. Pin in your compose/.env via the image tag so a rebuild
# is deterministic. The `wal-g-pg-ubuntu-22.04` binary is glibc-linked and
# runs on the Debian-based postgres image without translation.
ARG WAL_G_VERSION=v3.0.5
ARG TARGETARCH

# Install WAL-G binary. apt is purged after install — final image only
# keeps the wal-g binary, ca-certificates, and the runtime libs.
RUN set -eux; \
    arch="${TARGETARCH:-amd64}"; \
    case "$arch" in \
      amd64) walg_arch=amd64 ;; \
      arm64) walg_arch=aarch64 ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl ca-certificates; \
    curl -fsSL "https://github.com/wal-g/wal-g/releases/download/${WAL_G_VERSION}/wal-g-pg-ubuntu-22.04-${walg_arch}.tar.gz" \
        -o /tmp/wal-g.tar.gz; \
    tar -xzf /tmp/wal-g.tar.gz -C /tmp; \
    mv "/tmp/wal-g-pg-ubuntu-22.04-${walg_arch}" /usr/local/bin/wal-g; \
    chmod +x /usr/local/bin/wal-g; \
    rm /tmp/wal-g.tar.gz; \
    apt-get purge -y --auto-remove curl; \
    rm -rf /var/lib/apt/lists/*; \
    /usr/local/bin/wal-g --version

# Entrypoint wrapper. Resolves *_FILE env vars (Docker secrets convention)
# into the env that WAL-G expects, then chains into the upstream postgres
# entrypoint. Transparent if no _FILE vars are set.
COPY entrypoint.sh /usr/local/bin/postgres-wal-g-entrypoint.sh
RUN chmod +x /usr/local/bin/postgres-wal-g-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/postgres-wal-g-entrypoint.sh"]
CMD ["postgres"]
