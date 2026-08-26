# shellcheck shell=bash
# Install mise + the runtimes/toolkit from the packages/mise-* lists, as the config user.
# `mise use -g` both writes ~/.config/mise/config.toml (declarative) and installs. Tool installs
# land on the volume via MISE_DATA_DIR (from the storage snippet, inherited by this phase). The
# storage snippet already puts the volume shims on PATH for non-interactive phases; here we also
# wire `mise activate` into .bashrc for the richer interactive experience (docs' recommended combo).
section "mise toolchain"

MISE="${HOME}/.local/bin/mise"
if [ ! -x "$MISE" ]; then
  step "installing mise"
  curl -fsSL https://mise.run | sh
else
  ok "mise already installed ($("$MISE" --version 2>/dev/null || echo present))"
fi

mapfile -t SPECS < <(grep -hvE '^\s*(#|$)' "${ORB_ROOT}/packages/mise-runtimes" "${ORB_ROOT}/packages/mise-tools")
[ ${#SPECS[@]} -gt 0 ] || die "no specs in packages/mise-runtimes + packages/mise-tools"

step "installing ${#SPECS[@]} tools via mise use -g (installs -> ${MISE_DATA_DIR:-default})"
"$MISE" use -g "${SPECS[@]}"
ok "mise toolchain ready ($("$MISE" ls --current 2>/dev/null | wc -l | tr -d ' ') tools)"

# Interactive shell integration. Guarded + appended after Ubuntu's non-interactive early-return
# in .bashrc, so it runs ONLY in interactive shells; shims (storage snippet) cover the rest.
ensure_line "${HOME}/.bashrc" 'command -v mise >/dev/null 2>&1 && eval "$(mise activate bash)"'
ok "wired mise activate into .bashrc (interactive)"
