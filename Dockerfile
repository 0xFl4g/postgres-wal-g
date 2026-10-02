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
#     --build-arg WAL_G_VERSION=v3.0.9 \
#     -t ghcr.io/0xfl4g/postgres-wal-g:18-v3.0.9 .
# =============================================================================

ARG POSTGRES_VERSION=18
# CI pins this to postgres:<major>@sha256:... so the scanned, tested and
# published images share one base; local builds follow the floating tag.
ARG BASE_IMAGE=postgres:${POSTGRES_VERSION}

FROM ${BASE_IMAGE}

# WAL-G version. This ARG is the single source of truth: build.yml reads it
# (and tags images with it), test.yml builds with it. The Ubuntu binaries are
# glibc-linked and run on the Debian-based postgres image without translation.
# We use the 22.04 builds (glibc 2.35): the 24.04 ones need a newer glibc than
# some Debian releases the postgres image may be based on.
ARG WAL_G_VERSION=v3.0.9
ARG TARGETARCH

# DL3003: the `cd /tmp` is scoped to this RUN. DL3008: pinning Debian package
# versions breaks on every point release; the weekly rebuild keeps them current.
# DL3005: apply Debian security updates; the grype gate requires fixable OS CVEs
# to be fixed at build time (the upstream postgres base image lags Debian).
# hadolint ignore=DL3003,DL3005,DL3008
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
      amd64) walg_arch=amd64 ;; \
      arm64) walg_arch=aarch64 ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    walg_inner="wal-g-pg-22.04-${walg_arch}"; \
    walg_url="https://github.com/wal-g/wal-g/releases/download/${WAL_G_VERSION}/${walg_inner}.tar.gz"; \
    apt-get update; \
    apt-get -y upgrade --no-install-recommends; \
    # ca-certificates stays installed: wal-g needs it for TLS to object storage.
    apt-get install -y --no-install-recommends curl ca-certificates; \
    cd /tmp; \
    curl -fsSLO "$walg_url"; \
    # Verify against the .sha256 published alongside the release asset.
    # Same-origin, so this catches corrupt/mixed-up downloads rather than a
    # compromised release — but it keeps Renovate version bumps hands-free.
    curl -fsSLO "${walg_url}.sha256"; \
    sha256sum -c "${walg_inner}.tar.gz.sha256"; \
    tar -xzf "${walg_inner}.tar.gz"; \
    # The real binary lives at wal-g.bin; /usr/local/bin/wal-g is the
    # entrypoint script, which unwraps *_FILE secrets first (see entrypoint.sh).
    mv "/tmp/${walg_inner}" /usr/local/bin/wal-g.bin; \
    chmod +x /usr/local/bin/wal-g.bin; \
    rm "/tmp/${walg_inner}.tar.gz" "/tmp/${walg_inner}.tar.gz.sha256"; \
    apt-get purge -y --auto-remove curl; \
    rm -rf /var/lib/apt/lists/*; \
    /usr/local/bin/wal-g.bin --version

# Entrypoint wrapper. Resolves *_FILE env vars (Docker secrets convention)
# into the env that WAL-G expects, then chains into the upstream postgres
# entrypoint. Transparent if no _FILE vars are set. Also installed as `wal-g`
# so `docker exec … wal-g` gets the same secrets.
COPY entrypoint.sh /usr/local/bin/postgres-wal-g-entrypoint.sh
RUN chmod +x /usr/local/bin/postgres-wal-g-entrypoint.sh; \
    ln -s postgres-wal-g-entrypoint.sh /usr/local/bin/wal-g

ENTRYPOINT ["/usr/local/bin/postgres-wal-g-entrypoint.sh"]
CMD ["postgres"]
