# shellcheck shell=bash
# Fail-closed preflight (omarchy's guard.sh shape, adapted to headless Ubuntu + single user).
# Aborts with a plain reason before anything is installed.

# Must NOT be root, and MUST be the config user (the root->user transition is bootstrap's job).
if [ "$(id -u)" -eq 0 ]; then
  die "orb setup runs as ${ORB_BOX_USER}, not root — bootstrap handles the root->user step"
fi
[ "$(id -un)" = "$ORB_BOX_USER" ] || die "run as ${ORB_BOX_USER} (currently $(id -un))"
sudo -n true 2>/dev/null || die "${ORB_BOX_USER} needs passwordless sudo for system operations"

# OS: Ubuntu 24.04 (hard-fail on non-Ubuntu; warn on a different Ubuntu release).
if [ -r /etc/os-release ]; then
  # shellcheck source=/dev/null
  . /etc/os-release
  [ "${ID:-}" = "ubuntu" ] || die "requires Ubuntu (found ID=${ID:-unknown})"
  [ "${VERSION_ID:-}" = "24.04" ] || warn "expected Ubuntu 24.04, found ${VERSION_ID:-unknown} — continuing"
else
  die "cannot read /etc/os-release — unknown OS"
fi

# Architecture.
[ "$(uname -m)" = "x86_64" ] || die "requires x86_64 (found $(uname -m))"

# Data volume must be a real mountpoint (root is small; heavy trees go here).
mountpoint -q "$ORB_BOX_DATA_MOUNT" || die "${ORB_BOX_DATA_MOUNT} is not mounted — attach + mount the data volume first"

# SSM reachable (secrets come from SSM at runtime) — warn only, may propagate late on boot.
if have aws; then
  aws sts get-caller-identity --region "$ORB_BOX_REGION" >/dev/null 2>&1 \
    || warn "aws sts get-caller-identity failed — SSM reads may fail until the instance profile propagates"
else
  step "aws CLI not yet installed — the apt phase installs it"
fi
getent hosts github.com >/dev/null 2>&1 || warn "cannot resolve github.com — network may be down"

ok "guards passed"
