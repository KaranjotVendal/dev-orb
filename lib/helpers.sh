# shellcheck shell=bash
# Shared, idempotent helpers for the setup phases. Sourced by setup.sh after logging.sh.

# have <cmd> — true if a command is on PATH.
have() { command -v "$1" >/dev/null 2>&1; }

# user_have <cmd> — true if <cmd> resolves on the target user's login PATH (mise shims,
# npm-global, ~/.local/bin all live under the user, not root's PATH).
user_have() {
  runuser -l "${SRA_TARGET_USER}" -c "command -v $1 >/dev/null 2>&1"
}

# run_as_user <shell-command> — run a command as the target user with a login shell,
# sourcing the data-volume env snippet first so mise (~/.local/bin), the npm-global
# prefix, and the caches on ${SRA_DATA_MOUNT} are all in scope. The snippet may not
# exist yet on the very first storage-phase run; the guard tolerates that.
run_as_user() {
  local env_snippet="${SRA_DATA_MOUNT}/state/sra-env.sh"
  runuser -l "${SRA_TARGET_USER}" -c "[ -f '${env_snippet}' ] && . '${env_snippet}'; export PATH=\"\$HOME/.local/bin:\$PATH\"; $1"
}

# require_root — most phases install system packages / write /etc; refuse to run unprivileged.
require_root() {
  [ "$(id -u)" -eq 0 ] || die "setup.sh must run as root (use: sudo ./setup.sh)"
}

# ensure_line <file> <line> — append <line> to <file> once (idempotent config edits).
ensure_line() {
  local file="$1" line="$2"
  touch "$file"
  grep -qsF -- "$line" "$file" || printf '%s\n' "$line" >>"$file"
}

# apt_get <args...> — apt-get with a dpkg-lock wait + retry. cloud-init / unattended-
# upgrades routinely hold the lock in the first minutes of boot.
apt_get() {
  local attempt
  for attempt in 1 2 3 4 5; do
    if DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 "$@"; then
      return 0
    fi
    warn "apt-get $* failed (attempt ${attempt}/5); retrying in 15s"
    sleep 15
  done
  return 1
}

# ssm_fetch <param-name> <yes|no decrypt> — fetch an SSM parameter value with a bounded
# retry (rides out IAM instance-profile propagation on a fresh boot). Prints the value
# on stdout; returns nonzero if every attempt failed. Never logs the value.
ssm_fetch() {
  local param_name="$1" with_decryption="$2" attempt value
  local decrypt=()
  [ "$with_decryption" = "yes" ] && decrypt=(--with-decryption)
  for attempt in $(seq 1 12); do
    if value="$(aws ssm get-parameter --region "${SRA_REGION}" "${decrypt[@]}" \
        --name "$param_name" --query Parameter.Value --output text 2>/dev/null)"; then
      printf '%s' "$value"
      return 0
    fi
    sleep 5
  done
  return 1
}

# ssm_value_ok <value> — true when a fetched param holds a real value (not the empty
# string and not the terraform-seeded "PLACEHOLDER" sentinel).
ssm_value_ok() {
  [ -n "$1" ] && [ "$1" != "PLACEHOLDER" ]
}

# run_migrations — apply timestamped one-off migrations from migrations/*.sh exactly
# once each, tracked by marker files (the omarchy migrations pattern). A fresh box has
# no markers, so every current migration is treated as ALREADY-APPLIED on the first
# setup run (the base phases already establish desired state); only migrations added
# LATER run on an existing box.
run_migrations() {
  local state_dir="${SRA_DATA_MOUNT}/state/migrations"
  local mig marker base
  install -d -o "${SRA_TARGET_USER}" -g "${SRA_TARGET_USER}" "$state_dir" 2>/dev/null || mkdir -p "$state_dir"
  shopt -s nullglob
  local migrations=("${SRA_SETUP_ROOT}"/migrations/*.sh)
  shopt -u nullglob
  [ ${#migrations[@]} -eq 0 ] && return 0
  section "migrations"
  # First-ever run: seed all markers so existing state is not re-migrated.
  if [ ! -f "${state_dir}/.seeded" ]; then
    for mig in "${migrations[@]}"; do touch "${state_dir}/$(basename "$mig")"; done
    touch "${state_dir}/.seeded"
    ok "seeded migration markers (fresh box — nothing to replay)"
    return 0
  fi
  for mig in "${migrations[@]}"; do
    base="$(basename "$mig")"
    marker="${state_dir}/${base}"
    if [ -f "$marker" ]; then continue; fi
    step "applying migration ${base}"
    # shellcheck source=/dev/null
    source "$mig"
    touch "$marker"
    ok "migration ${base} applied"
  done
}