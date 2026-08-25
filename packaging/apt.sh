# shellcheck shell=bash
# Base packages + aws CLI v2. Reads the apt-base.packages manifest and installs only
# what is missing. fd on Ubuntu ships as `fdfind`; a `fd` shim is linked for the agents.
section "apt base packages"
require_root

MANIFEST="${SRA_SETUP_ROOT}/packaging/apt-base.packages"
mapfile -t WANT < <(grep -vE '^\s*(#|$)' "$MANIFEST")

# dpkg-query is the idempotency check: only apt-get install packages not already present.
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

systemctl enable --now ssh 2>/dev/null || true

# fd shim: agents call `fd`, Ubuntu's binary is `fdfind`. Link into /usr/local/bin once.
if have fdfind && ! have fd; then
  ln -sf "$(command -v fdfind)" /usr/local/bin/fd
  ok "linked fd -> fdfind"
fi

# aws CLI v2 (Ubuntu does not ship it). Arch-aware; the EC2 t3 target is x86_64.
if ! have aws; then
  step "installing aws CLI v2"
  tmp="$(mktemp -d)"
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o "${tmp}/awscliv2.zip"
  unzip -q "${tmp}/awscliv2.zip" -d "${tmp}"
  "${tmp}/aws/install" --update
  rm -rf "${tmp}"
  ok "aws CLI v2 installed"
else
  ok "aws CLI already present ($(aws --version 2>&1 | head -1))"
fi