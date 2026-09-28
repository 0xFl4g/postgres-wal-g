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
