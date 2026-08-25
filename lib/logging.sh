# shellcheck shell=bash
# Sectioned logging for setup.sh. Every message is teed to SRA_LOG_FILE with a
# timestamp so a run is auditable after the fact (the omarchy install-log pattern),
# and echoed to the console with a consistent `sra-setup:` prefix.

_sra_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_sra_emit() {
  # _sra_emit <level> <message>
  local level="$1"; shift
  local line
  line="$(_sra_ts) sra-setup[${level}]: $*"
  printf '%s\n' "$line"
  # Best-effort file log; never let a log-write failure abort the run.
  { printf '%s\n' "$line" >>"${SRA_LOG_FILE}"; } 2>/dev/null || true
}

start_log() {
  # Create the log file up front so every later append succeeds. Root-owned; the
  # phases that drop to the target user still read/append fine (0644).
  { install -m 0644 /dev/null "${SRA_LOG_FILE}"; } 2>/dev/null || true
  _sra_emit info "log started -> ${SRA_LOG_FILE}"
}

section() { printf '\n'; _sra_emit info "== $* =="; }
step()    { _sra_emit info "-> $*"; }
ok()      { _sra_emit info "ok $*"; }
warn()    { _sra_emit warn "$*" >&2; }

die() {
  _sra_emit error "$*" >&2
  exit 1
}