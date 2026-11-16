#!/usr/bin/env bash
# orb bootstrap.sh — one-command orchestrator (Mac-side). Delivers orb + config + agent files to the
# box, runs setup.sh (the phases), then doctor.sh (verify), adds the box to this Mac's herdr-core,
# and prints a final status plus the one-time interactive-auth reminder.
# Composes push-to-vm.sh -> setup.sh -> doctor.sh -> hc machine add.
#
# NOT in scope (kept separate, on purpose): `terraform apply` (provisioning) and the interactive
# agent auth (claude /login, slack /mcp, datadog /ddsetup) — the latter can't be scripted.
#
# Usage:
#   ./bootstrap.sh [--host <ssh_host>] [--config <path>] [--skip-push]
set -euo pipefail

ORB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ORB_ROOT
# shellcheck source=lib/logging.sh
source "${ORB_ROOT}/lib/logging.sh"

# have <cmd> — true if a command is on PATH.
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOF'
Usage: bootstrap.sh [--host <ssh_host>] [--config <path>] [--skip-push]

One command: deliver orb + config + agent files to the box, run setup.sh, then doctor.sh,
then add the box to this Mac's herdr-core (hc machine add --install).

  --host <ssh_host>   SSH host to bootstrap (default: [box].ssh_host in the config, else orb-vm)
  --config <path>     Path to the box config.toml (default: ~/.config/orb/config.toml)
  --skip-push         Skip the delivery step (orb + config already on the box)
  -h, --help          Show this help and exit
EOF
}

ssh_host=""
config_path="${HOME}/.config/orb/config.toml"
skip_push=0

while [ $# -gt 0 ]; do
  case "$1" in
    --host)      ssh_host="$2"; shift 2 ;;
    --config)    config_path="$2"; shift 2 ;;
    --skip-push) skip_push=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           die "unknown argument: $1" ;;
  esac
done

have ssh || die "ssh not found on PATH"
[ -f "$config_path" ] || die "config not found: ${config_path}"

# Host precedence: --host, then [box].ssh_host from the config, then the default orb-vm.
if [ -z "$ssh_host" ]; then
  ssh_host="$(python3 "${ORB_ROOT}/lib/config.py" "${config_path}" env \
    | grep '^ORB_BOX_SSH_HOST=' \
    | sed -e 's/^ORB_BOX_SSH_HOST=//' -e "s/^'//" -e "s/'$//" || true)"
fi
[ -n "$ssh_host" ] || ssh_host="orb-vm"

section "bootstrap ${ssh_host}"

# 1. Deliver orb + config + per-machine agent files (push-to-vm keeps .git for worktrees).
if [ "$skip_push" -eq 1 ]; then
  warn "skipping delivery (--skip-push) — assuming orb + config are already on ${ssh_host}"
else
  step "delivering orb + config + agent files"
  "${ORB_ROOT}/push-to-vm.sh" --host "$ssh_host" --config "$config_path"
fi

# 2. Configure the box. The box's config always lands at ~/config.toml (push-to-vm delivers it
# there). setup.sh sources orb-env.sh itself + /etc/environment carries the toolchain, so a bare
# non-login ssh exec resolves the tools — no `bash -lc` needed. A setup failure aborts (set -e).
step "running setup.sh on ${ssh_host}"
ssh "$ssh_host" 'cd ~/orb && ./setup.sh --config ~/config.toml'

# setup (config/storage) just wrote /etc/environment — the non-login toolchain env. Drop any reused
# SSH master (ControlMaster), which was opened during delivery BEFORE that and captured the
# pre-setup env; otherwise doctor, which relies on the session PATH, would see no toolchain and
# report false failures. The next ssh reconnects fresh with the new env. No-op if no master.
ssh -O exit "$ssh_host" 2>/dev/null || true

# 3. Verify. doctor exits non-zero on any failed check — capture it and report, don't abort.
step "running doctor.sh on ${ssh_host}"
if ssh "$ssh_host" 'cd ~/orb && ./doctor.sh --config ~/config.toml'; then
  ok "health check passed"
else
  warn "doctor reported failures on ${ssh_host} — review the output above"
fi

# 4. herdr-core. The Mac copies its own hc to the box and starts the box's core, so both stay on
# the same version. First restart the box user's systemd manager: it started before setup added
# the user to groups such as docker, and hc's core runs under it, so terminals would otherwise
# miss those groups. On a fresh box nothing else runs under it yet. Skipped when the box is
# already an hc machine (restarting would end its running terminals).
if ! have hc; then
  warn "hc not found on this Mac — skipping herdr-core; run: hc machine add ${ssh_host} --install"
elif hc machine ls --json 2>/dev/null | python3 -c 'import json, sys; target = sys.argv[1]; machines = json.load(sys.stdin).get("machines", []); sys.exit(0 if any(machine.get("target") == target for machine in machines) else 1)' "$ssh_host"; then
  ok "${ssh_host} is already an hc machine — leaving its core alone"
else
  step "restarting the box user's systemd manager so new group memberships apply"
  ssh "$ssh_host" 'sudo systemctl restart "user@$(id -u).service"' || warn "could not restart the user manager on ${ssh_host}"
  step "adding ${ssh_host} to herdr-core (hc machine add --install)"
  if hc machine add "$ssh_host" --install; then
    ok "herdr-core running on ${ssh_host}"
  else
    warn "hc machine add failed — retry by hand: hc machine add ${ssh_host} --install"
  fi
fi

# 5. Remind about the one-time interactive auth (cannot be scripted; see README).
section "next: one-time interactive agent auth (see README)"
step "claude: ssh ${ssh_host}, run claude, then /login"
step "slack plugin: in claude run /mcp -> slack (needs ssh -L 3118:localhost:3118)"
step "datadog plugin: in claude run /ddsetup (pick your site), then complete OAuth"

ok "bootstrap complete -> ${ssh_host}"
