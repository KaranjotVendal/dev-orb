#!/usr/bin/env bash
set -euo pipefail

# push-to-vm.sh — Mac-side delivery tool for orb. Rsyncs the orb repo, the box config, the
# per-machine agent files (pi auth.json/settings.json, claude CLAUDE.md, codex auth.json), and the config's
# rsync-source work repos (keeping .git so the box can spin worktrees) from this Mac to the box.
# It does NOT run setup.sh and does NOT commit anything — delivery only.

ORB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/logging.sh
source "${ORB_ROOT}/lib/logging.sh"

# have <cmd> — true if a command is on PATH.
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOF'
Usage: push-to-vm.sh [--host <ssh_host>] [--config <path>] [--dry-run]

Mac-side delivery: rsyncs the orb repo, box config, the per-machine agent files
(pi auth.json/settings.json, claude CLAUDE.md, codex auth.json), and the config's
rsync-source work repos (keeping .git) to the box. Does not run setup.sh, does not commit.

  --host <ssh_host>   SSH host to deliver to (default: [box].ssh_host from the config, else orb-vm)
  --config <path>     Path to the box config.toml (default: ~/.config/orb/config.toml)
  --dry-run           Pass --dry-run to rsync and skip remote mkdir/chmod side effects
  -h, --help          Show this help and exit
EOF
}

ssh_host=""
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
have rsync   || die "rsync not found on PATH"
have ssh     || die "ssh not found on PATH"
have python3 || die "python3 not found on PATH"   # reads the config's [[repos]] for group 5
[ -f "$config_path" ] || die "config not found: ${config_path}"

# Host precedence: --host, then the config's [box].ssh_host, then the neutral default.
if [ -z "$ssh_host" ]; then
  ssh_host="$(python3 "${ORB_ROOT}/lib/config.py" "${config_path}" env \
    | grep '^ORB_BOX_SSH_HOST=' \
    | sed -e 's/^ORB_BOX_SSH_HOST=//' -e "s/^'//" -e "s/'$//" || true)"
fi
[ -n "$ssh_host" ] || ssh_host="orb-vm"

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

# Group 5 — codex per-machine files: auth.json (codex-cli credentials — OpenAI API key + ChatGPT
# OAuth tokens; tokens self-refresh). codex-cli self-manages its config.toml + skills, and its herdr
# hook is installed by config/agent-env, so auth is the only thing delivered here.
section "codex agent files"
if [ "$dry_run" -eq 0 ]; then
  ssh "${ssh_host}" 'mkdir -p .codex'
fi
mac_codex_auth="${HOME}/.codex/auth.json"
if [ -f "$mac_codex_auth" ]; then
  step "rsync ${mac_codex_auth} -> ${ssh_host}:.codex/auth.json"
  rsync "${rsync_opts[@]}" "$mac_codex_auth" "${ssh_host}:.codex/auth.json"
  [ "$dry_run" -eq 0 ] && ssh "${ssh_host}" 'chmod 600 .codex/auth.json'
  ok "codex auth.json delivered"
else
  warn "codex auth.json: not found at ${mac_codex_auth} — skipping"
fi

# Group 6 — work repos. For each config [[repos]] entry with source="rsync", rsync it to the box
# KEEPING .git (the box spins worktrees off it), honoring the repo's own .gitignore (junk stays
# out), excluding .worktrees (the box makes its own), and force-including the repo's `include`
# patterns (gitignored files to bundle anyway, e.g. .env). The slowest group, so it runs last.
section "work repos"

# config.py env emits bare `ORB_BOX_DATA_MOUNT='/mnt/data'` (no `export`, value quoted). `|| true`
# so a no-match doesn't abort under `set -e`/pipefail — we fall back below.
data_mount="$(python3 "${ORB_ROOT}/lib/config.py" "${config_path}" env \
  | grep '^ORB_BOX_DATA_MOUNT=' \
  | sed -e 's/^ORB_BOX_DATA_MOUNT=//' -e "s/^'//" -e "s/'$//" -e 's/^"//' -e 's/"$//' || true)"
[ -n "$data_mount" ] || data_mount="/mnt/data"

repo_failures=0
# Read the repo list on FD 3, not stdin — otherwise rsync/ssh inside the loop consume the
# process-substitution input and the loop stops after the first repo.
# repo_flags consumes the flags TSV field (uv_sync etc.); delivery does not use it.
# shellcheck disable=SC2034
# Fields are split on \037 (unit separator), not tab: tab is IFS whitespace, so `read` would
# collapse an empty middle field (e.g. no flags) and shift `include` into the wrong variable.
while IFS=$'\037' read -r repo_name repo_source repo_ref repo_dest repo_flags repo_include <&3; do
  [ -n "$repo_name" ] || continue
  [ "$repo_source" = "rsync" ] || continue

  mac_source="${repo_ref/#\~/$HOME}"
  box_target="${data_mount}/${repo_dest}"

  if [ ! -d "$mac_source" ]; then
    warn "${repo_name}: Mac source not found at ${mac_source} — skipping"
    repo_failures=$((repo_failures + 1))
    continue
  fi

  # Force-include the repo's gitignored-but-wanted patterns (| -separated) BEFORE the .gitignore
  # filter, so they win over it (first-match-wins in rsync filter order).
  include_args=()
  if [ -n "$repo_include" ]; then
    IFS='|' read -ra include_patterns <<< "$repo_include"
    for pattern in "${include_patterns[@]}"; do
      include_args+=(--include="$pattern")
    done
  fi

  step "rsync ${repo_name} (${mac_source}) -> ${ssh_host}:${box_target}/"
  if [ "$dry_run" -eq 0 ]; then
    # -n: don't read stdin (the loop's stdin is the repos process substitution).
    ssh -n "${ssh_host}" "mkdir -p '${box_target}'"
  fi
  # KEEP .git (worktrees). Force-includes first, then honor .gitignore, then drop .worktrees.
  # ${arr[@]+"${arr[@]}"} expands to nothing when include_args is empty (safe under `set -u`).
  rsync "${rsync_opts[@]}" ${include_args[@]+"${include_args[@]}"} \
    --filter=':- .gitignore' --exclude='.worktrees/' \
    "${mac_source}/" "${ssh_host}:${box_target}/"
  ok "${repo_name} delivered"
done 3< <(python3 "${ORB_ROOT}/lib/config.py" "${config_path}" repos | tr '\t' '\037')

[ "$repo_failures" -eq 0 ] || warn "${repo_failures} work repo(s) skipped — see above"

ok "push-to-vm complete -> ${ssh_host}"
