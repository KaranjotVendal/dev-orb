# shellcheck shell=bash
# Clone / converge the sold-rate-agent repo on the data volume and sync its venv. The
# feedback loop runs from here. Never force-resets a dirty tree — warns instead, so an
# in-progress investigation on the box is never clobbered by a re-run.
section "sold-rate-agent repo"
require_root

if [ -z "${SRA_REPO_SLUG}" ]; then
  warn "SRA_REPO_SLUG unset — skipping repo clone/sync (set it per box: SRA_REPO_SLUG=your-org/repo)"
  return 0 2>/dev/null || exit 0
fi

install -d -o "${SRA_TARGET_USER}" -g "${SRA_TARGET_USER}" "$(dirname "${SRA_REPO_DIR}")"

if [ -d "${SRA_REPO_DIR}/.git" ]; then
  step "repo present — fetching + converging ${SRA_REPO_BRANCH}"
  run_as_user "cd '${SRA_REPO_DIR}' && git fetch --quiet origin"
  if run_as_user "cd '${SRA_REPO_DIR}' && ! git diff --quiet"; then
    warn "working tree at ${SRA_REPO_DIR} is dirty — leaving as-is (not resetting)"
  else
    run_as_user "cd '${SRA_REPO_DIR}' && git checkout --quiet '${SRA_REPO_BRANCH}' && git pull --quiet --ff-only origin '${SRA_REPO_BRANCH}'"
    ok "repo on ${SRA_REPO_BRANCH} at $(run_as_user "cd '${SRA_REPO_DIR}' && git rev-parse --short HEAD")"
  fi
else
  step "cloning ${SRA_REPO_SLUG} -> ${SRA_REPO_DIR}"
  # gh clone uses the credential wired in the secrets phase; falls back to plain HTTPS.
  if run_as_user "gh repo clone '${SRA_REPO_SLUG}' '${SRA_REPO_DIR}' -- --branch '${SRA_REPO_BRANCH}'"; then
    ok "cloned via gh"
  else
    run_as_user "git clone --branch '${SRA_REPO_BRANCH}' 'https://github.com/${SRA_REPO_SLUG}.git' '${SRA_REPO_DIR}'" \
      || die "clone failed — is gh authenticated (secrets phase) and the branch correct?"
    ok "cloned via git https"
  fi
fi

# Sync the venv with uv (cache on the volume via UV_CACHE_DIR from the storage snippet).
if [ -f "${SRA_REPO_DIR}/pyproject.toml" ]; then
  step "uv sync"
  run_as_user "cd '${SRA_REPO_DIR}' && ~/.local/bin/mise exec -- uv sync" \
    && ok "uv sync complete" \
    || warn "uv sync failed — resolve dependencies manually then re-run"
else
  warn "no pyproject.toml at ${SRA_REPO_DIR} — skipping uv sync"
fi