#!/usr/bin/env bash
# sra-vm-infra setup.sh — idempotent, sectioned bootstrap that turns a fresh Ubuntu
# 24.04 x86_64 server into the sold-rate-agent feedback-loop VM. Re-runnable to
# converge; reusable to spin up future boxes. Lives OUTSIDE the Terraform boundary
# (Terraform provisions the bare VM; this configures it), run post-boot over SSM/SSH.
#
# Shape borrowed from omarchy: a single entry point that sources helper libs, runs a
# fail-closed preflight, then works through packaging -> config -> login phases. Every
# step guards on "already present" so a second run is a near no-op.
#
# Usage (run as root, e.g. `sudo ./setup.sh`):
#   ./setup.sh                 run every phase (login phase is interactive)
#   ./setup.sh -y              skip the interactive login phase (unattended SSM runs)
#   ./setup.sh --only <phase>  run one phase: guard|apt|mise|agents|storage|secrets|repo|services|login
#   ./setup.sh --list          list phases and exit
set -eEo pipefail

SRA_SETUP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SRA_SETUP_ROOT

# --- Config contract (env-overridable so the script is reusable for a future VM) ----
export SRA_TARGET_USER="${SRA_TARGET_USER:-sra}"
export SRA_TARGET_HOME="${SRA_TARGET_HOME:-/home/${SRA_TARGET_USER}}"
export SRA_DATA_MOUNT="${SRA_DATA_MOUNT:-/mnt/sra-data}"
export SRA_SSM_PREFIX="${SRA_SSM_PREFIX:-/sold-rate-agent/vm}"
export SRA_REGION="${SRA_REGION:-eu-west-1}"
export SRA_REPO_SLUG="${SRA_REPO_SLUG:-}"   # e.g. your-org/sold-rate-agent — set per box
export SRA_REPO_BRANCH="${SRA_REPO_BRANCH:-feat/wire-metrics}"
export SRA_REPO_DIR="${SRA_REPO_DIR:-${SRA_DATA_MOUNT}/work/sold-rate-agent}"
export SRA_GIT_EMAIL="${SRA_GIT_EMAIL:-}"   # git identity for clone/commit — set per box
export SRA_GIT_NAME="${SRA_GIT_NAME:-}"
export SRA_FEEDBACK_LOOP_SLACK_CHANNEL="${SRA_FEEDBACK_LOOP_SLACK_CHANNEL:-}"  # Slack channel id for the digest
export SRA_BITBUCKET_ORG="${SRA_BITBUCKET_ORG:-}"  # org for the circli/bbcli HTTPS clone
export SRA_LOG_FILE="${SRA_LOG_FILE:-/var/log/sra-setup.log}"

# --- Load helpers -------------------------------------------------------------------
# shellcheck source=lib/logging.sh
source "${SRA_SETUP_ROOT}/lib/logging.sh"
# shellcheck source=lib/helpers.sh
source "${SRA_SETUP_ROOT}/lib/helpers.sh"

trap 'die "failed at line ${LINENO} (last command exited ${?})"' ERR

# --- Phase table --------------------------------------------------------------------
PHASES=(guard apt storage mise agents secrets repo services)

phase_file() {
  case "$1" in
    guard)    echo "preflight/guard.sh" ;;
    apt)      echo "packaging/apt.sh" ;;
    mise)     echo "packaging/mise.sh" ;;
    agents)   echo "packaging/agent-stack.sh" ;;
    storage)  echo "config/storage.sh" ;;
    secrets)  echo "config/secrets.sh" ;;
    repo)     echo "config/repo.sh" ;;
    services) echo "config/services.sh" ;;
    login)    echo "login/auth.sh" ;;
    *)        return 1 ;;
  esac
}

run_phase() {
  local name="$1" file
  file="$(phase_file "$name")" || die "unknown phase: ${name}"
  # shellcheck source=/dev/null
  source "${SRA_SETUP_ROOT}/${file}"
}

# --- Arg parsing --------------------------------------------------------------------
SKIP_LOGIN=0
ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes)   SKIP_LOGIN=1 ;;
    --only)     ONLY="${2:-}"; shift ;;
    --list)     printf '%s\n' "${PHASES[@]}" login; exit 0 ;;
    -h|--help)  sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)          die "unknown argument: $1" ;;
  esac
  shift
done

main() {
  start_log
  section "sra-vm setup starting (user=${SRA_TARGET_USER} mount=${SRA_DATA_MOUNT} region=${SRA_REGION})"

  if [ -n "$ONLY" ]; then
    # Always run the guard first even for a single phase, unless the guard itself is asked for.
    [ "$ONLY" = "guard" ] || run_phase guard
    run_phase "$ONLY"
    section "done (--only ${ONLY})"
    return 0
  fi

  for name in "${PHASES[@]}"; do
    run_phase "$name"
  done

  # Migrations: one-off deltas that must run once on existing boxes (omarchy pattern).
  run_migrations

  if [ "$SKIP_LOGIN" -eq 1 ]; then
    warn "skipping interactive login phase (-y). Run 'sudo ./setup.sh --only login' with a human attached."
  else
    run_phase login
  fi

  section "setup complete. Run 'sra-doctor' to verify."
}

main "$@"
