# shellcheck shell=bash
# System essentials from packages/apt, + aws CLI v2. Per-step idempotency: only install what
# is missing; the aws install is guarded. System ops via sudo. The CLI toolkit comes from mise.
section "base packages"

mapfile -t WANT < <(grep -vE '^\s*(#|$)' "${ORB_ROOT}/packages/apt")
[ ${#WANT[@]} -gt 0 ] || die "no packages listed in packages/apt"

MISSING=()
for pkg in "${WANT[@]}"; do
  dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed" || MISSING+=("$pkg")
done

if [ ${#MISSING[@]} -gt 0 ]; then
  step "installing: ${MISSING[*]}"
  apt_get update -y
  apt_get install -y "${MISSING[@]}"
else
  ok "all base packages already installed"
fi

# openssh backs the SSM-tunnelled rsync deploy; enable it (non-fatal).
as_root systemctl enable --now ssh 2>/dev/null || warn "could not enable ssh service"

# aws CLI v2 (Ubuntu does not ship it). Arch-aware; the EC2 t3 target is x86_64.
if have aws; then
  ok "aws CLI already present ($(aws --version 2>&1 | head -1))"
else
  step "installing aws CLI v2"
  tmp="$(mktemp -d)"
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o "${tmp}/awscliv2.zip"
  unzip -q "${tmp}/awscliv2.zip" -d "${tmp}"
  as_root "${tmp}/aws/install" --update
  rm -rf "${tmp}"
  ok "aws CLI v2 installed"
fi
