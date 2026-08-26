from __future__ import annotations

import sys
import tomllib
from pathlib import Path

# Reader for the box config.toml (see config.example.toml). Consumed by bootstrap.sh /
# setup.sh via two modes:
#
#   python3 lib/config.py <file> env
#       Emit shell assignments for the scalar sections (box/git/agents/tools) as
#       ORB_<SECTION>_<KEY>=value lines, for `eval "$(...)"` in bash.
#
#   python3 lib/config.py <file> repos
#       Emit one tab-separated line per [[repos]] entry:
#       name<TAB>source<TAB>ref<TAB>dest<TAB>flags
#       where ref is the url (clone) or rsync_path (rsync), and flags is a comma list
#       (e.g. "branch=main,uv_sync,uv_tool_install"). Loop over it in bash with read -r.

SCALAR_SECTIONS = ("box", "git", "agents", "tools")


def load(path: Path) -> dict:
    with path.open("rb") as handle:
        return tomllib.load(handle)


def shell_quote(value: str) -> str:
    # Single-quote for safe `eval` in bash; escape embedded single quotes.
    escaped = value.replace("'", "'\\''")
    return f"'{escaped}'"


def emit_env(config: dict) -> None:
    for section in SCALAR_SECTIONS:
        for key, value in (config.get(section) or {}).items():
            if isinstance(value, bool):
                rendered = "true" if value else "false"
            elif isinstance(value, list):
                rendered = " ".join(str(item) for item in value)
            else:
                rendered = str(value)
            print(f"ORB_{section.upper()}_{key.upper()}={shell_quote(rendered)}")


def emit_repos(config: dict) -> None:
    for repo in config.get("repos") or []:
        source = repo.get("source", "clone")
        ref = repo.get("url") if source == "clone" else repo.get("rsync_path", "")
        flags: list[str] = []
        if repo.get("branch"):
            flags.append(f"branch={repo['branch']}")
        if repo.get("uv_sync"):
            flags.append("uv_sync")
        if repo.get("uv_tool_install"):
            flags.append("uv_tool_install")
        fields = [repo.get("name", ""), source, ref or "", repo.get("dest", ""), ",".join(flags)]
        print("\t".join(fields))


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
