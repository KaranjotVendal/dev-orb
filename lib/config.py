from __future__ import annotations

import sys
import tomllib
from pathlib import Path

# Reader for the box config.toml (see config.example.toml). setup.sh consumes it in two modes:
#
#   python3 lib/config.py <file> env
#       Emit ORB_<SECTION>_<KEY>=value shell assignments for the scalar sections
#       (box/git/agents/tools), for `eval "$(...)"`. Booleans render true/false, lists
#       space-join, everything else str(). Fails closed if a required [box] key is absent.
#       Optional keys pass through the same way, e.g. [box].ssh_host -> ORB_BOX_SSH_HOST
#       (the Mac-side scripts' default SSH host).
#
#   python3 lib/config.py <file> repos
#       Emit one tab-separated line per [[repos]] entry:
#           name<TAB>source<TAB>ref<TAB>dest<TAB>flags
#       ref is the url (clone) or rsync_path (rsync); flags is a comma list
#       (branch=<b>,uv_sync,uv_tool_install). Loop with `while IFS=$'\t' read -r ...`.

SCALAR_SECTIONS = ("box", "git", "agents", "tools")
REQUIRED_BOX_KEYS = ("user", "data_mount", "region")
VALID_SOURCES = ("clone", "rsync")


def load(path: Path) -> dict:
    with path.open("rb") as handle:
        return tomllib.load(handle)


def die(message: str) -> None:
    print(f"config.py: {message}", file=sys.stderr)
    raise SystemExit(1)


def shell_quote(value: str) -> str:
    # Single-quote for safe `eval` in bash; escape any embedded single quote.
    escaped = value.replace("'", "'\\''")
    return f"'{escaped}'"


def render_scalar(value: object) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, list):
        return " ".join(str(item) for item in value)
    return str(value)


def emit_env(config: dict) -> None:
    box = config.get("box") or {}
    missing = [key for key in REQUIRED_BOX_KEYS if not box.get(key)]
    if missing:
        die(f"[box] is missing required key(s): {', '.join(missing)}")
    for section in SCALAR_SECTIONS:
        for key, value in (config.get(section) or {}).items():
            print(f"ORB_{section.upper()}_{key.upper()}={shell_quote(render_scalar(value))}")


def emit_repos(config: dict) -> None:
    for index, repo in enumerate(config.get("repos") or []):
        name = repo.get("name", "")
        label = name or f"#{index}"
        source = repo.get("source", "clone")
        if source not in VALID_SOURCES:
            die(f"repo {label}: source must be one of {'/'.join(VALID_SOURCES)} (got {source!r})")
        ref = repo.get("url") if source == "clone" else repo.get("rsync_path")
        if not ref:
            needed = "url" if source == "clone" else "rsync_path"
            die(f"repo {label}: {source} source requires '{needed}'")
        flags: list[str] = []
        if repo.get("branch"):
            flags.append(f"branch={repo['branch']}")
        if repo.get("uv_sync"):
            flags.append("uv_sync")
        if repo.get("uv_tool_install"):
            flags.append("uv_tool_install")
        # Optional rsync force-include patterns (pipe-joined 6th field): gitignored files to bundle
        # anyway (e.g. ".env", "docs/", "docs/HANDOFF.md"). push-to-vm applies them before the
        # .gitignore filter.
        include = repo.get("include") or []
        if not isinstance(include, list) or not all(isinstance(entry, str) for entry in include):
            die(f"repo {label}: 'include' must be a list of strings")
        print("\t".join([name, source, ref, repo.get("dest", ""), ",".join(flags), "|".join(include)]))


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[2] not in ("env", "repos"):
        print("usage: config.py <config.toml> <env|repos>", file=sys.stderr)
        return 2
    config = load(Path(argv[1]))
    if argv[2] == "env":
        emit_env(config)
    else:
        emit_repos(config)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
