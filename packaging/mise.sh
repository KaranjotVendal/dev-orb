# shellcheck shell=bash
# Install mise (if absent) under the target user, apply the pinned mise.toml, and
# activate it in the user's bash rc. All runtime installs happen as the target user so
# the toolchain, caches, and shims live under their home / the data volume — never root.
section "mise toolchain"
require_root

MISE_BIN="${SRA_TARGET_HOME}/.local/bin/mise"

if [ ! -x "$MISE_BIN" ]; then
  step "installing mise for ${SRA_TARGET_USER}"
  run_as_user 'curl -fsSL https://mise.run | sh'
else
  ok "mise already installed ($("$MISE_BIN" --version 2>/dev/null || echo present))"
fi

# Apply the pinned config: copy mise.toml -> ~sra/.config/mise/config.toml.
step "applying mise.toml"
install -d -o "${SRA_TARGET_USER}" -g "${SRA_TARGET_USER}" "${SRA_TARGET_HOME}/.config/mise"
install -m 0644 -o "${SRA_TARGET_USER}" -g "${SRA_TARGET_USER}" \
  "${SRA_SETUP_ROOT}/mise.toml" "${SRA_TARGET_HOME}/.config/mise/config.toml"

# Materialise the pinned versions (idempotent — mise skips already-installed tools).
run_as_user '$HOME/.local/bin/mise install'

# Activate mise in interactive shells (idempotent grep-guard inside ensure_line, run as
# the user so ownership stays correct).
BASHRC="${SRA_TARGET_HOME}/.bashrc"
if ! grep -qsF 'mise activate bash' "$BASHRC" 2>/dev/null; then
  printf '\n# mise version manager\neval "$(~/.local/bin/mise activate bash)"\n' >>"$BASHRC"
  chown "${SRA_TARGET_USER}:${SRA_TARGET_USER}" "$BASHRC"
  ok "added mise activation to ${BASHRC}"
fi

ok "mise toolchain ready: $(run_as_user '$HOME/.local/bin/mise ls --current 2>/dev/null | tr "\n" " "' || true)"