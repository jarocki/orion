#!/usr/bin/env bash
# shellcheck shell=bash
#
# @decision DEC-PHASE12-027
# @title Orion-X DuckDB optional installer (logquery accelerator)
# @status accepted
# @rationale orionx-logquery runs every preset report on stdlib sqlite3, so
#   nothing here is required to do forensics on this deck. DuckDB is offered
#   only as an accelerator for operators working large captures — millions of
#   rows, where columnar aggregation is genuinely faster than SQLite's
#   row-store.
#
#   It is an optional installer rather than a package-list entry because
#   DuckDB is not in Debian main: shipping it would mean vendoring a
#   per-architecture wheel of tens of megabytes into the ISO and pinning a
#   digest to chase on every release, to accelerate a query that already
#   completes in milliseconds at incident scale. That trade does not pay.
#
#   Nothing in Orion-X degrades if this is never run. orionx-logquery only
#   uses DuckDB when explicitly asked with --engine duckdb, and if it is
#   absent it prints one sentence naming this script instead of an
#   ImportError traceback.
#
# @decision DEC-PHASE11-011
# @title Orion-X optional-installer framework
# @status accepted
# @rationale Sources the shared installer library for DRY preflight checks,
#   log helpers, and install helpers.
#
# Usage (as root on a network-connected node):
#   sudo /opt/orionx/optional/install-duckdb.sh
#
# What this installs:
#   duckdb Python module (MIT) via pip, into the system site-packages
#   Size:        ~50 MB installed
#   Requires:    python3-pip, network access to pypi.org
#   Mission verb: analyze (large-capture query acceleration)
#
# Verify afterwards with:
#   orionx-logquery --path /var/log --report summary --engine duckdb

set -euo pipefail

# SC1091: library lives at runtime path /opt/orionx/optional/lib/ on the
# target system; shellcheck cannot follow the absolute path on the build host.
# shellcheck disable=SC1091
source /opt/orionx/optional/lib/orionx-installer-common.sh

orionx_require_root
orionx_require_network pypi.org

orionx_log_info "=== Orion-X optional installer: DuckDB ==="
orionx_log_info "  Size:    ~50 MB installed"
orionx_log_info "  License: MIT (duckdb/duckdb)"
orionx_log_info "  Network: pypi.org (wheel download)"
orionx_log_info "  Mission: analyze — accelerate orionx-logquery on large captures"
orionx_log_info ""
orionx_log_info "  NOT required. orionx-logquery runs every report on the"
orionx_log_info "  Python standard library's sqlite3 by default."

orionx_log_info "Ensuring python3-pip is installed..."
orionx_apt_install python3-pip

# --break-system-packages: Debian marks the system interpreter EXTERNALLY-
# MANAGED (PEP 668). A venv is the usual answer, but orionx-logquery runs as
# the system python3 from a /usr/bin symlink, so a venv it never activates
# would install a module the tool cannot import — an accelerator that
# silently does nothing. Installing into the system site-packages is the
# option where "installed" and "usable by the tool" mean the same thing.
orionx_log_info "Installing the duckdb Python module..."
pip3 install --break-system-packages duckdb

if python3 -c "import duckdb; print(duckdb.__version__)" >/dev/null 2>&1; then
    version="$(python3 -c "import duckdb; print(duckdb.__version__)")"
    orionx_log_info "DuckDB $version installed and importable."
    orionx_log_info "Use it with: orionx-logquery --engine duckdb ..."
else
    orionx_log_error "duckdb installed but is not importable by system python3."
    orionx_log_error "orionx-logquery will keep using sqlite3; no capability lost."
    exit 1
fi
