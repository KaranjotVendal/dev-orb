# shellcheck shell=bash
# Shared helpers for the orb phases. Single-user model: everything runs as the config user
# (ORB_BOX_USER); system operations use sudo. No runuser / ownership reconciliation.

# have <cmd> — true if a command is on PATH.
have() { command -v "$1" >/dev/null 2>&1; }

# as_root <cmd...> — run a system command with root privileges (sudo unless already root).
as_root() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

# apt_get <args...> — apt-get (as root) with a dpkg-lock wait + retry. cloud-init /
# unattended-upgrades routinely hold the lock in the first minutes of boot. Fails closed
# after the retries so the phase aborts rather than proceeding on a half-install.
apt_get() {
  local attempt
  for attempt in 1 2 3 4 5; do
    if as_root env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 "$@"; then
      return 0
    fi
    warn "apt-get $* failed (attempt ${attempt}/5); retrying in 15s"
    sleep 15
  done
  return 1
}

# ensure_line <file> <line> — append <line> to <file> once (idempotent config edits).
ensure_line() {
  local file="$1" line="$2"
  touch "$file"
  grep -qsF -- "$line" "$file" || printf '%s\n' "$line" >>"$file"
}

# load_config <path> — parse the TOML config into ORB_* env vars via lib/config.py, and
# export them so phases (run in subshells) inherit them.
load_config() {
  local config_path="$1"
  [ -f "$config_path" ] || die "config not found: ${config_path}"
  set -a
  eval "$(python3 "${ORB_ROOT}/lib/config.py" "$config_path" env)"
  set +a
  : "${ORB_BOX_USER:?config missing [box].user}"
  : "${ORB_BOX_DATA_MOUNT:?config missing [box].data_mount}"
  : "${ORB_BOX_REGION:?config missing [box].region}"
}
