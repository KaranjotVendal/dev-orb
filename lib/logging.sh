# shellcheck shell=bash
# Sectioned logging for orb. _orb_emit writes to the console (which setup.sh tees into
# ORB_LOG_FILE), with a consistent `orb:` prefix and a UTC timestamp.

_orb_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_orb_emit() {
  local level="$1"; shift
  printf '%s orb[%s]: %s\n' "$(_orb_ts)" "$level" "$*"
}

section() { printf '\n'; _orb_emit info "== $* =="; }
step()    { _orb_emit info "-> $*"; }
ok()      { _orb_emit info "ok $*"; }
warn()    { _orb_emit warn "$*" >&2; }
die()     { _orb_emit error "$*" >&2; exit 1; }
