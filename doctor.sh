#!/usr/bin/env bash
# orb doctor.sh — read-only health check for an orb box. Verifies each phase's outcome is present
# and working, prints one line per check, and exits non-zero if any check FAILS. The automated form
# of the README "Validate" checklist — run it after setup.sh, or later to catch drift. Never fixes.
# Run AS the config user, on the box.
#
# Usage:
#   ./doctor.sh --config /path/to/config.toml
set -uo pipefail   # NOT -e — run every check even when earlier ones fail.

ORB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ORB_ROOT

ORB_CONFIG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config)  ORB_CONFIG="${2:-}"; shift ;;
    -h|--help) sed -n '2,10p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)         echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
export ORB_CONFIG="${ORB_CONFIG:-}"
[ -n "$ORB_CONFIG" ] || { echo "error: no config (pass --config)" >&2; exit 2; }

# shellcheck source=lib/logging.sh
source "${ORB_ROOT}/lib/logging.sh"
# shellcheck source=lib/helpers.sh
source "${ORB_ROOT}/lib/helpers.sh"
load_config "$ORB_CONFIG"

# --- check plumbing: pass/bad track a failure count; a failing check never aborts the run. ---
doctor_fails=0
pass() { ok "$1"; }
bad()  { _orb_emit error "FAIL — $1" >&2; doctor_fails=$((doctor_fails + 1)); }
# ck <desc> <cmd...> — pass if the command succeeds, else bad.
ck() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$desc"; else bad "$desc"; fi; }

# --- storage ---
section "storage"
ck "data volume mounted at ${ORB_BOX_DATA_MOUNT}" mountpoint -q "$ORB_BOX_DATA_MOUNT"
if [ "$(readlink "${HOME}/dev" 2>/dev/null)" = "${ORB_BOX_DATA_MOUNT}/dev" ]; then
  pass "${HOME}/dev -> ${ORB_BOX_DATA_MOUNT}/dev"
else
  bad "${HOME}/dev is not a symlink to ${ORB_BOX_DATA_MOUNT}/dev"
fi
ck "orb-env.sh present" test -f "${ORB_BOX_DATA_MOUNT}/state/orb-env.sh"
ck "/etc/environment carries MISE_DATA_DIR (non-login toolchain env)" \
  grep -q '^MISE_DATA_DIR=' /etc/environment
ck "/etc/environment PATH includes the mise shims" \
  grep -q "${ORB_BOX_DATA_MOUNT}/mise/shims" /etc/environment

# --- toolchain ---
section "toolchain"
for tool in node python uv gh claude pi codex; do
  ck "${tool} on PATH" have "$tool"
done

# --- secrets ---
section "secrets"
ck "git identity set" test -n "$(git config --global user.email)"
ck "gh authenticated" gh auth status

# --- repos ---
section "repos"
# Read the repo list on FD 3 so nothing inside the loop can consume it. Fields: name, source,
# ref, dest, flags, include — only name/source/dest are used (`_` discards the rest).
while IFS=$'\t' read -r repo_name repo_source _ repo_dest _ _ <&3; do
  [ -n "$repo_name" ] || continue
  repo_dir="${ORB_BOX_DATA_MOUNT}/${repo_dest}"
  if [ ! -d "$repo_dir" ]; then
    bad "${repo_name}: MISSING at ${repo_dir}"
  elif [ "$repo_source" = "rsync" ] && [ ! -d "${repo_dir}/.git" ]; then
    bad "${repo_name}: present but no .git (worktrees won't work) at ${repo_dir}"
  else
    pass "${repo_name} present at ${repo_dir}"
  fi
done 3< <(python3 "${ORB_ROOT}/lib/config.py" "${ORB_CONFIG}" repos)

# --- agent-env ---
section "agent-env"
if [ "${ORB_AGENTS_REPLICATE_DEV_ENV:-false}" != "true" ]; then
  warn "replicate_dev_env is false — skipping agent-env checks"
else
  configure="${ORB_AGENTS_CONFIGURE:-both}"

  for skills_link in "${HOME}/.agents/skills" "${HOME}/.pi/agent/skills" "${HOME}/.claude/skills"; do
    ck "skills symlink resolves: ${skills_link}" test -d "$skills_link"
  done

  if [ "$configure" = "pi" ] || [ "$configure" = "both" ]; then
    ck "pi extensions installed" test -d "${HOME}/.pi/agent/npm/node_modules"
  fi

  if [ "$configure" = "claude" ] || [ "$configure" = "both" ]; then
    ck "claude settings.json present" test -f "${HOME}/.claude/settings.json"
    if have claude; then
      if claude plugin list 2>/dev/null | grep -qi 'enabled'; then
        pass "claude has enabled plugins"
      else
        bad "no claude plugins enabled"
      fi
    fi
  fi
fi

# --- summary ---
section "summary"
if [ "$doctor_fails" -eq 0 ]; then
  ok "all checks passed"
  exit 0
fi
_orb_emit error "${doctor_fails} check(s) FAILED" >&2
exit 1
