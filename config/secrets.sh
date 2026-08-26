# shellcheck shell=bash
# Generic box secrets (nothing baked): git identity (from config) + gh auth (GitHub token from
# SSM, needed so the repos phase can clone/commit private repos). orb is reusable tooling, so
# project/tool-specific secrets are NOT wired here — the project and the login phase do that.
section "secrets (git + gh)"

# git identity (non-secret; from config).
if [ -n "${ORB_GIT_EMAIL:-}" ] && [ -n "${ORB_GIT_NAME:-}" ]; then
  step "git identity -> ${ORB_GIT_NAME} <${ORB_GIT_EMAIL}>"
  git config --global user.email "$ORB_GIT_EMAIL"
  git config --global user.name "$ORB_GIT_NAME"
else
  warn "[git].name/email not set in config — skipping git identity"
fi

# GitHub token -> gh auth (drives private clone/commit via gh's credential helper).
if ! have gh; then
  warn "gh not on PATH — cannot authenticate GitHub (the mise toolkit should provide gh)"
elif gh auth status >/dev/null 2>&1; then
  ok "gh already authenticated"
else
  gh_token="$(ssm_fetch "${ORB_BOX_SSM_PREFIX}/github/token" yes || true)"
  if ssm_value_ok "$gh_token"; then
    step "authenticating gh with the GitHub token"
    printf '%s' "$gh_token" | gh auth login --with-token --hostname github.com --git-protocol https && gh auth setup-git \
      && ok "gh authenticated + git credential helper wired"
  else
    warn "${ORB_BOX_SSM_PREFIX}/github/token unset in SSM — gh not authenticated; private clone/push will fail"
  fi
  unset gh_token
fi
