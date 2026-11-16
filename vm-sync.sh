#!/usr/bin/env bash
set -euo pipefail

# vm-sync.sh — send the exact current state of ONE repo or worktree from this Mac to the box, so
# work can continue there. One-way (Mac -> box), never deletes anything on the box, never touches
# the Mac's files. Layout matches push-to-vm: ~/dev/<rel> lands at <data_mount>/dev/<rel>.

# Resolve symlinks so ORB_ROOT is the repo even when run via a ~/.local/bin symlink.
script_path="${BASH_SOURCE[0]}"
while [ -L "$script_path" ]; do
  link_target="$(readlink "$script_path")"
  case "$link_target" in
    /*) script_path="$link_target" ;;
    *)  script_path="$(dirname "$script_path")/${link_target}" ;;
  esac
done
ORB_ROOT="$(cd "$(dirname "$script_path")" && pwd -P)"
# shellcheck source=lib/logging.sh
source "${ORB_ROOT}/lib/logging.sh"
# shellcheck source=lib/helpers.sh
source "${ORB_ROOT}/lib/helpers.sh"

usage() {
  cat <<'EOF'
Usage: vm-sync [--host <ssh_host>] [--config <path>] [--dry-run] [PATH]

Send the exact current state of one git repo or worktree (PATH, default: the current
directory) from this Mac to the box, uncommitted changes included. One-way, Mac to box.
Never deletes anything on the box and never modifies the Mac's files.

The repo's top level must live under ~/dev; ~/dev/<rel> lands at <data_mount>/dev/<rel>
on the box. Gitignored files are skipped, except the matching config [[repos]] entry's
`include` patterns; .worktrees/ is skipped.

  Main checkout   the working tree is rsynced including .git.
  Worktree        the working tree is rsynced without .git, the main repo's git dir is
                  rsynced to <dest>/.git (minus worktrees/), and HEAD is pointed at the
                  worktree's branch (or commit, if detached) with the index refreshed, so the
                  box copy is a standalone repo showing the same uncommitted changes.
                  The first sync of a large main repo's .git can take a while; rsync is
                  incremental, so repeat syncs are fast.

  --host <ssh_host>   SSH host (default: [box].ssh_host from the config, else orb-vm)
  --config <path>     Path to the box config.toml (default: ~/.config/orb/config.toml)
  --dry-run           Pass --dry-run to rsync and skip remote mkdir/git side effects
  -h, --help          Show this help and exit
EOF
}

ssh_host=""
config_path="${HOME}/.config/orb/config.toml"
dry_run=0
target_path="."

while [ $# -gt 0 ]; do
  case "$1" in
    --host)    ssh_host="$2"; shift 2 ;;
    --config)  config_path="$2"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)        die "unknown argument: $1" ;;
    *)         target_path="$1"; shift ;;
  esac
done

# Preconditions.
have git     || die "git not found on PATH"
have rsync   || die "rsync not found on PATH"
have ssh     || die "ssh not found on PATH"
have python3 || die "python3 not found on PATH"
[ -f "$config_path" ] || die "config not found: ${config_path}"
[ -d "$target_path" ] || die "not a directory: ${target_path}"

# config_value <KEY> — the unquoted value of an ORB_* line from config.py env, or empty.
config_env="$(python3 "${ORB_ROOT}/lib/config.py" "${config_path}" env)" \
  || die "invalid config: ${config_path} (see the error above)"
config_value() {
  printf '%s\n' "$config_env" \
    | grep "^$1=" \
    | sed -e "s/^$1=//" -e "s/^'//" -e "s/'$//" || true
}

[ -n "$ssh_host" ] || ssh_host="$(config_value ORB_BOX_SSH_HOST)"
[ -n "$ssh_host" ] || ssh_host="orb-vm"
data_mount="$(config_value ORB_BOX_DATA_MOUNT)"
[ -n "$data_mount" ] || data_mount="/mnt/data"

# Resolve the repo. Physical paths throughout so the ~/dev prefix check is reliable.
top_level="$(git -C "$target_path" rev-parse --show-toplevel 2>/dev/null)" \
  || die "not inside a git repository: ${target_path}"
top_level="$(cd "$top_level" && pwd -P)"
git_dir="$(cd "$top_level" && cd "$(git rev-parse --git-dir)" && pwd -P)"
common_git_dir="$(cd "$top_level" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"

dev_root="$(cd "${HOME}/dev" 2>/dev/null && pwd -P)" || die "${HOME}/dev not found"
case "$top_level" in
  "${dev_root}"/*) relative_path="${top_level#"${dev_root}"/}" ;;
  *)               die "repo is not under ~/dev: ${top_level}" ;;
esac
box_target="${data_mount}/dev/${relative_path}"

if [ -d "${top_level}/.git" ]; then
  repo_kind="main"
  main_top_level="$top_level"
elif [ -f "${top_level}/.git" ] && [ "$git_dir" != "$common_git_dir" ]; then
  repo_kind="worktree"
  main_top_level="$(dirname "$common_git_dir")"
else
  die "unsupported .git layout at ${top_level} (neither a main checkout nor a worktree)"
fi

# Force-include patterns from the config [[repos]] entry whose rsync_path is this repo (or, for a
# worktree, its main repo). No match is fine: ad hoc repos sync with no extra includes.
include_args=()
matched_repo_name=""
# repo_dest/repo_flags consume TSV fields this script does not use.
# shellcheck disable=SC2034
# Fields are split on \037 (unit separator), not tab: tab is IFS whitespace, so `read` would
# collapse an empty middle field (e.g. no flags) and shift `include` into the wrong variable.
while IFS=$'\037' read -r repo_name repo_source repo_ref repo_dest repo_flags repo_include <&3; do
  [ "$repo_source" = "rsync" ] || continue
  expanded_path="${repo_ref/#\~/$HOME}"
  [ -d "$expanded_path" ] || continue
  expanded_path="$(cd "$expanded_path" && pwd -P)"
  [ "$expanded_path" = "$main_top_level" ] || continue
  matched_repo_name="$repo_name"
  if [ -n "$repo_include" ]; then
    IFS='|' read -ra include_patterns <<< "$repo_include"
    for pattern in "${include_patterns[@]}"; do
      include_args+=(--include="$pattern")
    done
  fi
  break
done 3< <(python3 "${ORB_ROOT}/lib/config.py" "${config_path}" repos | tr '\t' '\037')

rsync_opts=(-a)
[ "$dry_run" -eq 1 ] && rsync_opts+=(--dry-run)

quoted_box_target="$(printf '%q' "$box_target")"

section "vm-sync ${relative_path} (${repo_kind})"
if [ -n "$matched_repo_name" ]; then
  step "config repo: ${matched_repo_name} (${#include_args[@]} include pattern(s))"
else
  step "no config repo matches ${main_top_level}; syncing with no extra includes"
fi

if [ "$dry_run" -eq 0 ]; then
  ssh -n "$ssh_host" "mkdir -p ${quoted_box_target}"
fi

if [ "$repo_kind" = "main" ]; then
  # Same as push-to-vm's work-repo rsync: KEEP .git, force-includes first, then honor .gitignore,
  # then drop .worktrees. No --delete.
  step "rsync ${top_level} -> ${ssh_host}:${box_target}/"
  rsync "${rsync_opts[@]}" ${include_args[@]+"${include_args[@]}"} \
    --filter=':- .gitignore' --exclude='.worktrees/' \
    "${top_level}/" "${ssh_host}:${box_target}/"
  head_description="branch $(git -C "$top_level" symbolic-ref -q --short HEAD || git -C "$top_level" rev-parse --short HEAD)"
else
  # The worktree's .git file points at a Mac path that does not exist on the box, so build a
  # standalone repo there: working tree without .git, then the main repo's git dir as .git.
  step "rsync worktree ${top_level} -> ${ssh_host}:${box_target}/"
  rsync "${rsync_opts[@]}" --exclude='/.git' ${include_args[@]+"${include_args[@]}"} \
    --filter=':- .gitignore' --exclude='.worktrees/' \
    "${top_level}/" "${ssh_host}:${box_target}/"

  step "rsync git dir ${common_git_dir} -> ${ssh_host}:${box_target}/.git/"
  rsync "${rsync_opts[@]}" --exclude='/worktrees/' \
    "${common_git_dir}/" "${ssh_host}:${box_target}/.git/"

  branch_ref="$(git -C "$top_level" symbolic-ref -q HEAD || true)"
  if [ -n "$branch_ref" ]; then
    head_command="git symbolic-ref HEAD $(printf '%q' "$branch_ref")"
    head_description="branch ${branch_ref#refs/heads/}"
  else
    head_sha="$(git -C "$top_level" rev-parse HEAD)"
    head_command="git update-ref --no-deref HEAD ${head_sha}"
    head_description="detached at ${head_sha:0:12}"
  fi

  if [ "$dry_run" -eq 0 ]; then
    step "point box HEAD at ${head_description} and refresh the index"
    # core.bare/core.worktree: make sure the copy is an ordinary non-bare repo rooted at <dest>.
    # git reset -q (mixed) rebuilds the index from HEAD without touching working files, so the
    # Mac's uncommitted changes show up as changes on the box.
    ssh -n "$ssh_host" "cd ${quoted_box_target} \
      && git config core.bare false \
      && { git config --unset core.worktree || true; } \
      && ${head_command} \
      && git reset -q"
  fi
fi

if [ "$dry_run" -eq 1 ]; then
  ok "dry run: would sync ${relative_path} -> ${ssh_host}:${box_target} (${repo_kind}, ${head_description})"
else
  ok "synced ${relative_path} -> ${ssh_host}:${box_target} (${repo_kind}, ${head_description})"
fi
