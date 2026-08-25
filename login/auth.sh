# shellcheck shell=bash
# The one interactive phase: authenticate Claude Code via device code. Run with a human
# attached (over the SSM session). Everything else in setup.sh is unattended; this is the
# single manual step the brief calls out. Idempotent — skips if already logged in.
section "interactive login"
require_root

if run_as_user 'claude whoami >/dev/null 2>&1 || claude auth status >/dev/null 2>&1'; then
  ok "Claude Code already logged in"
else
  step "starting Claude Code device-code login (follow the URL + code below)"
  # Hand the terminal to the target user's claude login. Interactive by design.
  runuser -l "${SRA_TARGET_USER}" -c 'claude login' \
    || warn "claude login did not complete — re-run: sudo ./setup.sh --only login"
fi

# gh-stack sometimes needs auth to install; retry now that gh is authenticated.
if [ -n "${SRA_GHSTACK_REPO:-}" ] && ! run_as_user "gh extension list 2>/dev/null | grep -qi gh-stack"; then
  run_as_user "gh extension install ${SRA_GHSTACK_REPO}" && ok "gh-stack installed" || warn "gh-stack install still failing"
fi