#!/usr/bin/env bash
# orb setup.sh — the config-driven configurer (layer 2 of two; bootstrap.sh is the
# orchestrator). Turns a resolved config into a working agent-workstation box on Ubuntu
# 24.04 x86_64. Runs AS the config user ([box].user) and refuses root — bootstrap handles
# the root->user transition. Idempotent + re-runnable.
#
# Phase model follows omarchy: each phase is a standalone script; this file is a list that
# runs each via run_phase (isolated subshell, per-phase logging + exit code). Phases are
# added one per increment.
#
# Usage (as the config user):
#   ORB_CONFIG=/path/to/config.toml ./setup.sh
#   ./setup.sh --config /path/to/config.toml [--only <phase>] [--list]
set -eEo pipefail

ORB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ORB_ROOT

# Ordered phase list (relative to ORB_ROOT, without .sh). Grows one entry per increment.
PHASES=(
  preflight/guard
  packaging/apt
  config/storage
  packaging/mise
  packaging/agents
  config/secrets
)

# --- args ---------------------------------------------------------------------------
ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config) ORB_CONFIG="${2:-}"; shift ;;
    --only)   ONLY="${2:-}"; shift ;;
    --list)   printf '%s\n' "${PHASES[@]}"; exit 0 ;;
    -h|--help) sed -n '2,14p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
export ORB_CONFIG="${ORB_CONFIG:-}"
[ -n "$ORB_CONFIG" ] || { echo "error: no config (set ORB_CONFIG or pass --config)" >&2; exit 2; }

# --- helpers + config ---------------------------------------------------------------
# shellcheck source=lib/logging.sh
source "${ORB_ROOT}/lib/logging.sh"
# shellcheck source=lib/helpers.sh
source "${ORB_ROOT}/lib/helpers.sh"
load_config "$ORB_CONFIG"

# --- logging: tee everything to the log so SSM runs stay observable -----------------
export ORB_LOG_FILE="${ORB_LOG_FILE:-${HOME}/.orb/setup.log}"
mkdir -p "$(dirname "$ORB_LOG_FILE")"
exec > >(tee -a "$ORB_LOG_FILE") 2>&1

# run_phase <rel> — run one phase script in an isolated subshell (inherits our helpers +
# exported ORB_* config), reporting per-phase status. A phase failure aborts the run.
run_phase() {
  local rel="$1" script="${ORB_ROOT}/$1.sh"
  [ -f "$script" ] || die "phase script not found: ${script}"
  section "phase: ${rel}"
  if ( set -eEo pipefail; source "$script" ); then
    ok "phase ${rel} complete"
  else
    die "phase ${rel} failed (exit $?) — see ${ORB_LOG_FILE}"
  fi
}

main() {
  section "orb setup (user=${ORB_BOX_USER} mount=${ORB_BOX_DATA_MOUNT} region=${ORB_BOX_REGION})"
  if [ -n "$ONLY" ]; then
    local match=""
    # Accept either the full phase path (as --list prints) or just its basename.
    for rel in "${PHASES[@]}"; do { [ "$rel" = "$ONLY" ] || [ "${rel##*/}" = "$ONLY" ]; } && match="$rel"; done
    [ -n "$match" ] || die "unknown phase: ${ONLY} (see --list)"
    run_phase "$match"
  else
    # Option A: after each phase, source the volume env snippet once storage has written it,
    # so the non-interactive install phases inherit it across the per-phase subshell boundary.
    local snippet="${ORB_BOX_DATA_MOUNT}/state/orb-env.sh"
    for rel in "${PHASES[@]}"; do
      run_phase "$rel"
      [ -f "$snippet" ] && . "$snippet"
    done
  fi
  section "setup complete"
}

main
