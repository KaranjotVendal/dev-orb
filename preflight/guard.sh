# shellcheck shell=bash
# Fail-closed preflight (the omarchy guard.sh pattern, adapted to headless Ubuntu on
# EC2). Aborts with a plain, single-line reason per failed condition BEFORE any package
# is installed or any file is written, so a wrong-shaped box never gets half-configured.

section "preflight guard"
require_root

# 1. OS: Ubuntu 24.04 (the settled base). Warn-only on a different Ubuntu release so a
#    point-release bump does not hard-block; hard-fail on a non-Ubuntu distro.
if [ -r /etc/os-release ]; then
  # shellcheck source=/dev/null
  . /etc/os-release
  [ "${ID:-}" = "ubuntu" ] || die "requires Ubuntu (found ID=${ID:-unknown})"
  [ "${VERSION_ID:-}" = "24.04" ] || warn "expected Ubuntu 24.04, found ${VERSION_ID:-unknown} — continuing"
else
  die "cannot read /etc/os-release — unknown OS"
fi

# 2. Architecture: x86_64 (the EC2 t3 target; aws CLI + mise pins assume it).
[ "$(uname -m)" = "x86_64" ] || die "requires x86_64 (found $(uname -m))"

# 3. Target user must exist (Terraform's user_data creates it; a bare box without it is
#    not ready for configuration).
id -u "${SRA_TARGET_USER}" >/dev/null 2>&1 || die "target user '${SRA_TARGET_USER}' does not exist — provision the VM (Terraform user_data) first"

# 4. Data volume must be a real mountpoint. Root is ~7 G; letting heavy trees land there
#    is the failure mode the /mnt/sra-data volume exists to prevent.
mountpoint -q "${SRA_DATA_MOUNT}" || die "${SRA_DATA_MOUNT} is not mounted — attach + mount the data volume before setup"

# 5. Instance profile / SSM reachable (secrets are pulled from SSM at runtime). A failed
#    identity call means no credentials — every secrets read would fail later; stop now.
if have aws; then
  aws sts get-caller-identity --region "${SRA_REGION}" >/dev/null 2>&1 \
    || warn "aws sts get-caller-identity failed — SSM reads may fail until the instance profile propagates"
else
  step "aws CLI not yet installed — the apt phase installs it"
fi

# 6. Network up (installs pull from apt / npm / mise / GitHub).
getent hosts github.com >/dev/null 2>&1 || warn "cannot resolve github.com — network may be down"

ok "guards passed"