# shellcheck shell=bash
# Replicate the user's live agent config onto the box, explicitly — not via appa's bootstrap.
# Built up one piece at a time. For now: the skills tree. appa/skills is the ONE canonical
# real directory; the box mirrors the Mac by pointing the shared + per-agent skills paths at it:
#   ~/.agents/skills, ~/.pi/agent/skills, ~/.claude/skills  ->  <appa>/skills
# appa is placed on the box by config/repos. Runs after config/repos; gated on replicate_dev_env.
# pi extensions: declared in ~/.pi/agent/settings.json (a per-machine file delivered Mac -> box);
# this phase realizes them with `pi update --extensions`. auth.json, settings.json, and
# AGENTS.md/CLAUDE.md are per-machine files delivered by push-to-vm.sh, not by this phase.
# Later piece: claude config.
section "agent-env (replicate agent config)"

[ "${ORB_AGENTS_REPLICATE_DEV_ENV:-false}" = "true" ] || { ok "replicate_dev_env is false — skipping agent config"; return 0; }

# Locate the agent-config repo ([agents].repo) via its [[repos]] dest, so we use wherever
# config/repos actually placed it.
: "${ORB_AGENTS_REPO:?config missing [agents].repo}"
agent_repo_dest="$(python3 "${ORB_ROOT}/lib/config.py" "$ORB_CONFIG" repos | awk -F'\t' -v name="$ORB_AGENTS_REPO" '$1 == name {print $4}')"
[ -n "$agent_repo_dest" ] || die "agent-env: [agents].repo '${ORB_AGENTS_REPO}' is not listed in [[repos]]"
agent_repo_dir="${ORB_BOX_DATA_MOUNT}/${agent_repo_dest}"
[ -d "$agent_repo_dir" ] || die "agent-env: ${ORB_AGENTS_REPO} not present at ${agent_repo_dir} — deliver it (push-to-vm.sh) first"

# Where displaced real files/dirs are moved before we replace them with the managed symlink.
AGENT_BACKUP_DIR="${HOME}/.orb-backups/agent-env-$(date -u +%Y%m%dT%H%M%SZ)"

# Point `link` at `target` as a symlink. If a real file/dir is already there (e.g. installer
# residue), back it up first — mirroring the HOME-relative path so same-basename links
# (~/.pi/agent/skills vs ~/.claude/skills) don't collide — then replace it. Idempotent.
link_managed() {
  local link="$1" target="$2"
  if [ -L "$link" ]; then
    [ "$(readlink "$link")" = "$target" ] || { rm "$link"; ln -s "$target" "$link"; }
  elif [ -e "$link" ]; then
    local backup="${AGENT_BACKUP_DIR}/${link#"$HOME"/}"
    mkdir -p "$(dirname "$backup")"
    mv "$link" "$backup"
    warn "backed up ${link} -> ${backup}"
    ln -s "$target" "$link"
  else
    mkdir -p "$(dirname "$link")"
    ln -s "$target" "$link"
  fi
  ok "${link} -> ${target}"
}

configure="${ORB_AGENTS_CONFIGURE:-both}"
skills_target="${agent_repo_dir}/skills"

# Shared agents skills path (not tied to a specific agent).
step "linking shared agents skills"
link_managed "${HOME}/.agents/skills" "$skills_target"

# --- pi: skills + extensions ---
if [ "$configure" = "pi" ] || [ "$configure" = "both" ]; then
  step "configuring pi (skills)"
  link_managed "${HOME}/.pi/agent/skills" "$skills_target"

  # Extensions are declared in the delivered settings.json; install/update the declared set.
  # Idempotent (a re-run is a no-op when everything is current). Warn-and-continue on failure.
  step "installing pi extensions (pi update --extensions)"
  if have pi; then
    if pi update --extensions; then
      ok "pi extensions installed/updated"
    else
      warn "pi update --extensions failed — continuing"
    fi
  else
    warn "pi not on PATH — skipping extension install"
  fi
fi

# --- claude: settings + skills + plugins ---
if [ "$configure" = "claude" ] || [ "$configure" = "both" ]; then
  # settings.json: a box-specific config shipped as an orb asset (prefs + the PreToolUse block
  # hooks with $HOME-relative paths that resolve to $HOME/dev/appa on the box + enabledPlugins for
  # the box's plugin set). COPIED, not symlinked — claude writes to settings.json, and the asset is
  # the seed/source of truth. Keep the asset's enabledPlugins in sync with the install list below.
  step "installing claude settings.json"
  claude_settings_src="${ORB_ROOT}/assets/claude/settings.json"
  if [ -f "$claude_settings_src" ]; then
    mkdir -p "${HOME}/.claude"
    cp "$claude_settings_src" "${HOME}/.claude/settings.json"
    ok "claude settings.json installed"
  else
    warn "claude settings asset missing at ${claude_settings_src} — skipping"
  fi

  step "configuring claude (skills)"
  link_managed "${HOME}/.claude/skills" "$skills_target"

  # Plugins: add the marketplaces, then install the box's plugin set. `claude plugin install`
  # also enables the plugin and writes its state, so this is independent of settings.json.
  # Idempotent (re-add/re-install are no-ops); warn-and-continue per plugin.
  # slack + datadog use interactive OAuth (slack `/mcp`, datadog `/ddsetup`) done once on the box
  # per the README runbook — both install fine here regardless of auth.
  step "installing claude plugins (marketplaces + plugins)"
  if have claude; then
    claude plugin marketplace add anthropics/claude-plugins-official >/dev/null 2>&1 || true
    claude plugin marketplace add backnotprop/plannotator >/dev/null 2>&1 || true
    for plugin in \
      frontend-design@claude-plugins-official \
      plannotator@plannotator \
      slack@claude-plugins-official \
      datadog@claude-plugins-official; do
      if claude plugin install "$plugin"; then
        ok "installed ${plugin}"
      else
        warn "failed to install ${plugin} — continuing"
      fi
    done
  else
    warn "claude not on PATH — skipping plugin install"
  fi
fi

ok "agent-env phase complete"
