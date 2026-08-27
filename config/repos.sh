# shellcheck shell=bash
# Place the repos from the config's [[repos]] table on the box, under ~/dev/<repo> (the
# storage phase symlinks ~/dev -> the durable volume). Each repo is either:
#   clone  — git-cloned here on the box from a URL (uses the gh credential helper the
#            secrets phase wired, so private repos work). If already present, left as-is
#            (idempotent; update it yourself with git pull).
#   rsync  — delivered from the Mac by push-to-vm.sh; this phase does NOT fetch it, it
#            only builds it if present and warns if not.
# Runs after config/secrets. Warn-and-continue per repo: one bad repo never aborts the phase.
section "repos"

repos_tsv="$(python3 "${ORB_ROOT}/lib/config.py" "$ORB_CONFIG" repos)" || die "invalid [[repos]] config"

# uv_sync / uv_tool_install post-steps (uv resolves via the mise shims on PATH).
run_post_steps() {
  local dir="$1" do_sync="$2" do_tool="$3"
  if [ "$do_sync" = 1 ]; then
    step "uv sync ${dir}"
    ( cd "$dir" && uv sync ) || return 1
  fi
  if [ "$do_tool" = 1 ]; then
    step "uv tool install --editable ${dir}"
    uv tool install --editable "$dir" || return 1
  fi
  return 0
}

place_repo() {
  local name="$1" source="$2" ref="$3" dest="$4" flags="$5"
  local dest_abs="${ORB_BOX_DATA_MOUNT}/${dest}"
  local branch="" do_sync=0 do_tool=0 flag
  local parsed
  IFS=',' read -ra parsed <<< "$flags"
  for flag in "${parsed[@]}"; do
    case "$flag" in
      branch=*)        branch="${flag#branch=}" ;;
      uv_sync)         do_sync=1 ;;
      uv_tool_install) do_tool=1 ;;
    esac
  done

  case "$source" in
    clone)
      if [ -d "${dest_abs}/.git" ]; then
        step "${name} already present at ${dest_abs} — leaving as-is"
      else
        step "clone ${name} -> ${dest_abs}"
        mkdir -p "$(dirname "$dest_abs")"
        if [ -n "$branch" ]; then
          git clone --branch "$branch" "$ref" "$dest_abs" || return 1
        else
          git clone "$ref" "$dest_abs" || return 1
        fi
      fi
      ;;
    rsync)
      if [ ! -d "$dest_abs" ]; then
        warn "${name}: rsync repo not present at ${dest_abs} — deliver it from the Mac (push-to-vm.sh)"
        return 0
      fi
      step "using rsynced ${name} (${dest_abs})"
      ;;
    *)
      warn "${name}: unknown source '${source}' — skipping"
      return 0
      ;;
  esac

  run_post_steps "$dest_abs" "$do_sync" "$do_tool" || return 1
  ok "${name} ready"
}

failures=0
while IFS=$'\t' read -r name source ref dest flags; do
  [ -n "$name" ] || continue
  place_repo "$name" "$source" "$ref" "$dest" "$flags" \
    || { warn "repo ${name} failed — continuing"; failures=$((failures + 1)); }
done <<< "$repos_tsv"

[ "$failures" -eq 0 ] || warn "${failures} repo(s) had problems — see above"
ok "repos phase complete"
