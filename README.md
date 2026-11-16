# orb

Reusable, idempotent tooling that turns a fresh Ubuntu 24.04 x86_64 EC2 box into an agent
workstation: the claude / pi / codex CLIs, a version-managed toolchain, your repos, and your
agent configuration (skills, extensions, plugins).

## How it is structured

Two layers:

- **`user_data.sh.tftpl`** — slim boot. Timezone, base packages, the AWS CLI, and the EBS data
  volume mounted at `[box].data_mount`. Nothing agent-specific.
- **`setup.sh`** — a config-driven phase runner. Each phase is a standalone script under
  `preflight/`, `packaging/`, or `config/`, run in an isolated subshell. Phases, in order:

  1. `preflight/guard` — sanity checks
  2. `packaging/apt` — OS packages
  3. `config/storage` — data-volume layout, `orb-env.sh` (caches + PATH on the volume)
  4. `packaging/mise` — the toolchain (node/python/uv + CLI tools) via mise
  5. `packaging/agents` — the claude / pi / codex agent CLIs
  6. `config/secrets` — git identity + gh auth (GitHub token from SSM)
  7. `config/repos` — place your repos under `~/dev/<repo>`
  8. `config/agent-env` — replicate agent config (skills, pi extensions, claude plugins)

Everything is idempotent — re-running a phase converges rather than duplicates.

## Prerequisites

- AWS credentials for the target account. aws/terraform commands need your AWS profile exported
  per shell (`export AWS_PROFILE=<your-profile>`).
- Terraform, for provisioning.
- SSM parameters preloaded (SecureString), under your `[box].ssm_prefix`:
  - `<ssm_prefix>/github/token` — a GitHub token, so `config/secrets` can auth `gh` for private
    clones.

## 1. Provision the box

```
export AWS_PROFILE=<your-profile>
terraform init
terraform apply
```

To rebuild from clean (wipe the data volume), taint the volume and replace the instance:

```
terraform apply -replace=aws_ebs_volume.data
```

## 2. Configure

Copy the example and fill in your values:

```
cp config.example.toml config.toml
```

Key fields: `[box]` (user, `data_mount`, region, `ssm_prefix`); `[[repos]]` (each repo's source
`clone`/`rsync`, ref, dest, post-step flags); `[agents]` (`configure` = claude|pi|both,
`replicate_dev_env`, `repo` = the repo holding your skills). Keep `config.toml` out of git.

## 3. Deliver orb + config to the box, then run setup

One command from your workstation delivers, configures, and verifies the box:

```
./bootstrap.sh --host <box>       # push-to-vm -> setup.sh -> doctor.sh, then reminds about auth
```

Or run the steps yourself:

```
./push-to-vm.sh --host <box>                    # delivers orb repo, config, + per-machine agent files
ssh <box> 'cd ~/orb && ./setup.sh --config ~/config.toml'
```

`setup.sh` sources `orb-env.sh` itself per phase and (via `config/storage`) writes
`/etc/environment`, so no login shell is needed. Useful flags:

- `./setup.sh --list` — print the phases
- `./setup.sh --config ~/config.toml --only config/agent-env` — run one phase

The SSH host comes from `--host`, else `[box].ssh_host` in the config, else `orb-vm`.

### Sync one repo or worktree: vm-sync

`vm-sync.sh` sends the exact current state of a single repo or worktree (uncommitted changes
included) to the box, so work can continue there. It is one-way (workstation to box), never
deletes anything on the box (no `rsync --delete`), and never modifies local files. Symlink it
onto your PATH, e.g. `ln -s "$PWD/vm-sync.sh" ~/.local/bin/vm-sync`.

```
vm-sync                                 # sync the repo containing the current directory
vm-sync ~/dev/your-cli                  # or a given path
vm-sync --dry-run                       # show what rsync would do; no remote changes
vm-sync --host orb-vm --config <path>   # override the config's ssh_host / config location
```

- The repo's top level must be under `~/dev`; `~/dev/<rel>` lands at `<data_mount>/dev/<rel>`,
  the same layout push-to-vm uses (so `~/dev/x-worktrees/y` lands at `dev/x-worktrees/y`).
- Same filters as push-to-vm: the `include` patterns of the matching `[[repos]]` entry (matched by
  `rsync_path`; a worktree matches its main repo's entry), then the repo's `.gitignore`, then
  `.worktrees/` excluded. Repos not in the config sync with no extra includes.
- **Main checkout**: the working tree is rsynced including `.git`.
- **Worktree**: its `.git` file points at a local path the box does not have, so the box copy is
  made a standalone repo: the working tree is rsynced without `.git`, the main repo's git dir is
  rsynced to `<dest>/.git` (minus `worktrees/`, so all local branches and unpushed commits come
  along), HEAD is set to the worktree's branch (or commit, if detached), and `git reset -q`
  refreshes the index. Uncommitted changes show as changes on the box; staged-only new files
  show as untracked there. The first sync of a large `.git` can be slow; repeats are incremental.

## 4. One-time interactive agent auth

Some agent auth is interactive (OAuth / subscription) and is not scripted — do it once per box.
Run these in a `claude` (or `pi`) session on the box.

### pi

pi reads credentials from `~/.pi/agent/auth.json` and config from `~/.pi/agent/settings.json`.
Deliver both from your workstation (these are per-machine files):

```
rsync -a ~/.pi/agent/auth.json     <box>:.pi/agent/auth.json
rsync -a ~/.pi/agent/settings.json <box>:.pi/agent/settings.json
```

`config/agent-env` then realizes the extensions declared in `settings.json`
(`pi update --extensions`).

### claude

Launch `claude` on the box and run `/login` (OAuth). If the login uses a localhost callback,
reconnect with `ssh -L <port>:localhost:<port> <box>` and retry.

### claude plugins

`config/agent-env` installs the plugin set. Self-contained plugins work immediately; MCP-backed
plugins need a one-time OAuth:

- **slack** — in `claude`, run `/mcp`, select slack, authenticate. The callback uses port 3118,
  so connect with `ssh -L 3118:localhost:3118 <box>` first, then open the printed URL in your
  browser.
- **datadog** — run `/ddsetup` **before** the `/mcp` Authenticate option (the MCP host is a
  `not-setup` placeholder until `/ddsetup` picks your site). Select your Datadog site — find it
  from your Datadog browser URL: plain `app.datadoghq.com` is `us1`, `app.datadoghq.eu` is `eu`,
  `app.us5.datadoghq.com` is `us5`, and so on — then complete the OAuth. `/ddtoolsets` picks
  which tool groups are enabled.

### herdr-core

The box runs herdr-core (`hc`), driven from the Mac. orb does not install it: once setup is done,
run `hc machine add <host> --install` on the Mac, which copies hc to the box and starts its core.
Claude Code reports its own working/idle/blocked status to herdr-core, so no hooks are needed.
The old herdr TUI and its per-agent integrations are no longer installed.

## 5. Validate

One command checks every phase's outcome (volume, toolchain, secrets, repos, agent config) and
exits non-zero if anything is broken — run it after setup, or later to catch drift:

```
ssh <box> 'cd ~/orb && ./doctor.sh --config ~/config.toml'
```

Or check individual pieces by hand:

```
ssh <box> 'claude plugin list'          # plugins installed + enabled
ssh <box> 'claude mcp list'             # MCP servers connected/authenticated
ssh <box> 'claude -p "list your skills"'
ssh <box> 'pi -p "list your skills"'
```

## Operational notes

- **Remote commands work non-login.** `config/storage` writes the toolchain env (PATH +
  `MISE_DATA_DIR` + caches) into `/etc/environment`, which PAM applies to every session type, so a
  bare `ssh <box> '<cmd>'` resolves `claude`/`pi`/`node` without needing `bash -lc`. (Interactive
  shells also source `orb-env.sh` via `.bashrc`/`.profile`.)
- **AWS profile per call.** Shell state does not persist between separate commands; export
  `AWS_PROFILE` in each aws/terraform invocation.
- **Connection reuse.** Enabling SSH `ControlMaster`/`ControlPersist` for the box host reuses one
  SSM tunnel across back-to-back ssh/rsync, avoiding a slow cold start on each call.
