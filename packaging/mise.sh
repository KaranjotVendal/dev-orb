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

mapfile -t SPECS < <(grep -hvE '^\s*(#|$)' "${ORB_ROOT}/packages/mise-runtimes" "${ORB_ROOT}/packages/mise-tools" "${ORB_ROOT}/packages/mise-agents")
[ ${#SPECS[@]} -gt 0 ] || die "no specs in packages/mise-runtimes + packages/mise-tools"

step "installing ${#SPECS[@]} tools via mise use -g (installs -> ${MISE_DATA_DIR:-default})"
"$MISE" use -g "${SPECS[@]}"
ok "mise toolchain ready ($("$MISE" ls --current 2>/dev/null | wc -l | tr -d ' ') tools)"

# claude-code ships its platform-native binary via a postinstall that mise's npm backend
# does not run, so the `claude` launcher aborts with "native binary not installed". Fetch
# it by running the package's install.cjs once. Idempotent (re-running just re-verifies);
# warn-and-continue so a fetch hiccup does not abort the whole toolchain phase. pi/codex
# are unaffected. (find avoids hardcoding the version or mise's nested .mise/ layout.)
if printf '%s\n' "${SPECS[@]}" | grep -q '@anthropic-ai/claude-code'; then
  claude_root="$("$MISE" where npm:@anthropic-ai/claude-code 2>/dev/null || true)"
  install_cjs=""
  [ -n "$claude_root" ] && install_cjs="$(find "$claude_root" -path '*/@anthropic-ai/claude-code/install.cjs' 2>/dev/null | head -1)"
  if [ -n "$install_cjs" ]; then
    step "fetching claude-code native binary (mise npm postinstall workaround)"
    if "$MISE" exec -- node "$install_cjs" >/dev/null 2>&1; then
      ok "claude-code native binary installed"
    else
      warn "claude-code postinstall failed — 'claude' may not run until it is re-fetched"
    fi
  else
    warn "claude-code install.cjs not found under ${claude_root:-<unresolved>} — 'claude' may not run"
  fi
fi

# Interactive shell integration. Guarded + appended after Ubuntu's non-interactive early-return
# in .bashrc, so it runs ONLY in interactive shells; shims (storage snippet) cover the rest.
ensure_line "${HOME}/.bashrc" 'command -v mise >/dev/null 2>&1 && eval "$(mise activate bash)"'
ok "wired mise activate into .bashrc (interactive)"
