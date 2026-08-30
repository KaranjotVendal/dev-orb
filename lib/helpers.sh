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

# ssm_fetch <param-name> <yes|no decrypt> — fetch an SSM parameter value with a bounded retry
# (rides out IAM instance-profile propagation on a fresh boot). Prints the value on stdout;
# nonzero if every attempt failed. Never logs the value.
ssm_fetch() {
  local param_name="$1" with_decryption="$2" attempt value
  local decrypt=()
  [ "$with_decryption" = "yes" ] && decrypt=(--with-decryption)
  for attempt in $(seq 1 12); do
    if value="$(aws ssm get-parameter --region "${ORB_BOX_REGION}" "${decrypt[@]}" \
        --name "$param_name" --query Parameter.Value --output text 2>/dev/null)"; then
      printf '%s' "$value"
      return 0
    fi
    sleep 5
  done
  return 1
}

# ssm_value_ok <value> — true when a fetched param holds a real value (not empty / PLACEHOLDER).
ssm_value_ok() { [ -n "$1" ] && [ "$1" != "PLACEHOLDER" ]; }

# load_config <path> — parse the TOML config into ORB_* env vars via lib/config.py, and
# export them so phases (run in subshells) inherit them.
load_config() {
  local config_path="$1"
  [ -f "$config_path" ] || die "config not found: ${config_path}"
  # Capture first so config.py's exit code is honored — `eval "$(...)"` would discard it and let a
  # rejected config (missing [box] key, bad repo) slip through to the :? backstop with a double
  # message. The assignment's exit status IS config.py's, so `|| die` aborts cleanly on failure.
  local rendered
  rendered="$(python3 "${ORB_ROOT}/lib/config.py" "$config_path" env)" \
    || die "invalid config: ${config_path} (see the error above)"
  set -a
  eval "$rendered"
  set +a
  # Backstop (config.py already validates these; kept as defense in depth).
  : "${ORB_BOX_USER:?config missing [box].user}"
  : "${ORB_BOX_DATA_MOUNT:?config missing [box].data_mount}"
  : "${ORB_BOX_REGION:?config missing [box].region}"
}
