# shellcheck shell=bash
# The agent stack: Claude Code, herdr, pi, circli, and gh (+ optional gh-stack). Runtimes
# come from mise (previous phase); these CLIs are installed on top via npm-global / curl /
# uv tool so each stays independently pinned. npm globals land on the data volume because
# run_as_user sources the storage env snippet (NPM_CONFIG_PREFIX -> ${SRA_DATA_MOUNT}).
# Runtime auth (tokens/keys) is NOT wired here — the secrets + login phases do that.
section "agent stack"
require_root

MISE='$HOME/.local/bin/mise'

# --- Claude Code (the workers). REQUIRED. -------------------------------------------
if user_have claude; then
  ok "Claude Code already installed"
else
  step "installing @anthropic-ai/claude-code"
  run_as_user "${MISE} exec -- npm install -g @anthropic-ai/claude-code"
  ok "Claude Code installed"
fi

# --- herdr (planner/implementer/reviewer panes + --remote). REQUIRED. ---------------
if user_have herdr; then
  ok "herdr already installed"
else
  step "installing herdr"
  run_as_user 'curl -fsSL https://herdr.dev/install.sh | sh'
  ok "herdr installed"
fi

# --- pi (worker runtime). REQUIRED. Installed via mise (see mise.toml, npm backend);
#     auth is handled out-of-band via codex device auth, not baked here.
if user_have pi; then ok "pi present (via mise)"; else warn "pi missing — run: mise install"; fi

# --- gh (GitHub CLI). RECOMMENDED. Official apt repo (keyring + sources, idempotent). --
if have gh; then
  ok "gh already installed ($(gh --version | head -1))"
else
  step "installing gh from the official apt repo"
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
  chmod 0644 /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    >/etc/apt/sources.list.d/github-cli.list
  apt_get update -y
  apt_get install -y gh
  ok "gh installed"
fi

# gh-stack extension (optional; set SRA_GHSTACK_REPO to enable). Needs gh present; the
# install is a no-op if already added.
if [ -n "${SRA_GHSTACK_REPO:-}" ]; then
  if run_as_user "gh extension list 2>/dev/null | grep -qi gh-stack"; then
    ok "gh-stack already installed"
  else
    step "installing gh-stack extension (${SRA_GHSTACK_REPO})"
    run_as_user "gh extension install ${SRA_GHSTACK_REPO}" || warn "gh-stack install failed (needs gh auth?) — retry after the login phase"
  fi
else
  step "SRA_GHSTACK_REPO unset — skipping gh-stack (optional)"
fi

# --- circli (CircleCI CLI; wraps the bbcli plugin). REQUIRED. -------------------------
# circli's pyproject pulls bbcli via a sibling path dependency (../bbcli), so BOTH source
# trees must sit side by side under ${SRA_DATA_MOUNT}/work before `uv tool install`.
# Source resolution, in order:
#   1. already-present source trees (rsynced from the Mac over the sra-fbl tunnel), or
#   2. HTTPS clone from Bitbucket using a credential in SSM (bitbucket/http-credential,
#      format "user:app-password").
# If neither is available, circli is SKIPPED with a clear warning (non-fatal) — the box
# is otherwise fully set up. See README "circli source on the VM".
WORK="${SRA_DATA_MOUNT}/work"
CIRCLI_SRC="${WORK}/circli"
BBCLI_SRC="${WORK}/bbcli"

circli_clone() {
  local cred repo_base
  cred="$(ssm_fetch "${SRA_SSM_PREFIX}/bitbucket/http-credential" yes || true)"
  if ! ssm_value_ok "$cred" || [ -z "${SRA_BITBUCKET_ORG:-}" ]; then
    return 1
  fi
  repo_base="https://${cred}@bitbucket.org/${SRA_BITBUCKET_ORG}"
  run_as_user "[ -d '${BBCLI_SRC}/.git' ] || git clone '${repo_base}/bbcli.git' '${BBCLI_SRC}'"
  run_as_user "[ -d '${CIRCLI_SRC}/.git' ] || git clone '${repo_base}/circli.git' '${CIRCLI_SRC}'"
}

if user_have circli; then
  ok "circli already installed"
elif { [ -d "$CIRCLI_SRC" ] && [ -d "$BBCLI_SRC" ]; } || circli_clone; then
  if [ -d "$CIRCLI_SRC" ] && [ -d "$BBCLI_SRC" ]; then
    step "installing circli from ${CIRCLI_SRC} (bbcli sibling at ${BBCLI_SRC})"
    run_as_user "${MISE} exec -- uv tool install --reinstall '${CIRCLI_SRC}'"
    ok "circli installed"
  else
    warn "circli source incomplete under ${WORK} — skipping (need both circli/ and bbcli/)"
  fi
else
  warn "no circli source and no bitbucket/http-credential SSM param — skipping circli. rsync circli+bbcli to ${WORK} or set the credential, then re-run."
fi