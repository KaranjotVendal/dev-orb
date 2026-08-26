# shellcheck shell=bash
# Shared helpers for the orb phases. Single-user model: everything runs as the config user
# (ORB_BOX_USER); system operations use sudo. No runuser / ownership reconciliation.

# have <cmd> — true if a command is on PATH.
have() { command -v "$1" >/dev/null 2>&1; }

# as_root <cmd...> — run a system command with root privileges (sudo unless already root).
as_root() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
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
