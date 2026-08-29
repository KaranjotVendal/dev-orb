#!/usr/bin/env bash
set -euo pipefail

# push-to-vm.sh — Mac-side delivery tool for orb. Rsyncs the orb repo, the box config, and the
# per-machine agent files (pi auth.json/settings.json, claude CLAUDE.md) from this Mac to the box.
# It does NOT run setup.sh and does NOT commit anything — delivery only. (Work-repo delivery is a
# later addition.)

ORB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/logging.sh
source "${ORB_ROOT}/lib/logging.sh"

# have <cmd> — true if a command is on PATH.
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOF'
Usage: push-to-vm.sh [--host <ssh_host>] [--config <path>] [--dry-run]

Mac-side delivery: rsyncs the orb repo, box config, and the per-machine agent
files (pi auth.json/settings.json, claude CLAUDE.md) to the box. Does not run
setup.sh and does not commit.

  --host <ssh_host>   SSH host to deliver to (default: sra-fbl)
  --config <path>     Path to the box config.toml (default: ~/.config/orb/config.toml)
  --dry-run           Pass --dry-run to rsync and skip remote mkdir/chmod side effects
  -h, --help          Show this help and exit
EOF
}

ssh_host="sra-fbl"
config_path="${HOME}/.config/orb/config.toml"
dry_run=0

while [ $# -gt 0 ]; do
  case "$1" in
    --host)    ssh_host="$2"; shift 2 ;;
    --config)  config_path="$2"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)         die "unknown argument: $1" ;;
  esac
done

# Preconditions.
have rsync || die "rsync not found on PATH"
have ssh   || die "ssh not found on PATH"
[ -f "$config_path" ] || die "config not found: ${config_path}"

rsync_opts=(-a)
[ "$dry_run" -eq 1 ] && rsync_opts+=(--dry-run)

# Group 1 — orb repo. Exclude terraform state/dirs: the box runs setup.sh, never terraform, and
# tfstate can hold sensitive values we don't want to ship there.
section "orb repo"
step "rsync orb -> ${ssh_host}:orb/"
rsync "${rsync_opts[@]}" \
  --exclude='.git' --exclude='__pycache__' --exclude='*.tfstate*' --exclude='.terraform/' \
  "${ORB_ROOT}/" "${ssh_host}:orb/"
ok "orb repo delivered"

# Group 2 — config.
section "config"
step "rsync ${config_path} -> ${ssh_host}:config.toml"
rsync "${rsync_opts[@]}" "${config_path}" "${ssh_host}:config.toml"
ok "config delivered"

# Group 3 — pi per-machine agent files. (Work-repo delivery — reading config [[repos]] and
# rsyncing each rsync-source repo while keeping .git for worktrees — is a deliberate later
# addition, not yet validated, so it is not wired here.)
section "pi agent files"

if [ "$dry_run" -eq 0 ]; then
  ssh "${ssh_host}" 'mkdir -p .pi/agent'
fi

pi_agent_dir="${HOME}/.pi/agent"
for pi_file in auth.json settings.json; do
  mac_pi_file="${pi_agent_dir}/${pi_file}"
  if [ ! -f "$mac_pi_file" ]; then
    warn "pi ${pi_file}: not found at ${mac_pi_file} — skipping"
    continue
  fi
  step "rsync ${mac_pi_file} -> ${ssh_host}:.pi/agent/${pi_file}"
  rsync "${rsync_opts[@]}" "${mac_pi_file}" "${ssh_host}:.pi/agent/${pi_file}"
  if [ "$pi_file" = "auth.json" ] && [ "$dry_run" -eq 0 ]; then
    ssh "${ssh_host}" 'chmod 600 .pi/agent/auth.json'
  fi
  ok "pi ${pi_file} delivered"
done

# Group 4 — claude per-machine files: CLAUDE.md (personal global instructions — too personal for
# the public orb repo, so delivered live from the Mac). The box's claude settings.json is a
# non-personal orb asset installed by config/agent-env, NOT delivered here.
section "claude agent files"
if [ "$dry_run" -eq 0 ]; then
  ssh "${ssh_host}" 'mkdir -p .claude'
fi
mac_claude_md="${HOME}/.claude/CLAUDE.md"
if [ -f "$mac_claude_md" ]; then
  step "rsync ${mac_claude_md} -> ${ssh_host}:.claude/CLAUDE.md"
  rsync "${rsync_opts[@]}" "$mac_claude_md" "${ssh_host}:.claude/CLAUDE.md"
  ok "claude CLAUDE.md delivered"
else
  warn "claude CLAUDE.md: not found at ${mac_claude_md} — skipping"
fi

ok "push-to-vm complete -> ${ssh_host}"
