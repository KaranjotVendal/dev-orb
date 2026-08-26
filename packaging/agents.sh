# shellcheck shell=bash
# Agent CLIs that mise can't install: herdr (curl script), gh-stack (a gh extension),
# plannotator (curl script). claude + pi (npm) come from mise via packages/mise-agents; gh
# (aqua) from mise via packages/mise-tools. Runtime auth is wired by the secrets/login phases.
section "agent stack (non-mise)"

if have herdr; then
  ok "herdr already installed"
else
  step "installing herdr"
  curl -fsSL https://herdr.dev/install.sh | sh
  ok "herdr installed"
fi

if have gh; then
  if gh extension list 2>/dev/null | grep -qi gh-stack; then
    ok "gh-stack already installed"
  else
    step "installing gh-stack extension"
    gh extension install github/gh-stack 2>/dev/null || warn "gh-stack install failed (gh auth needed? retries after login)"
  fi
else
  warn "gh not on PATH yet — skipping gh-stack (mise toolkit should provide gh)"
fi

if [ "${ORB_TOOLS_PLANNOTATOR:-false}" = "true" ]; then
  if have plannotator; then
    ok "plannotator already installed"
  else
    step "installing plannotator CLI"
    curl -fsSL https://plannotator.ai/install.sh | bash || warn "plannotator install failed"
  fi
fi
