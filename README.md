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

- AWS credentials for the target account (this repo pins `AWS_PROFILE=mlops`; adjust for yours).
  aws/terraform commands need the profile exported per shell.
- Terraform, for provisioning.
- SSM parameters preloaded (SecureString), under your `[box].ssm_prefix`:
  - `<ssm_prefix>/github/token` — a GitHub token, so `config/secrets` can auth `gh` for private
    clones.

## 1. Provision the box

```
export AWS_PROFILE=mlops
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

```
./push-to-vm.sh --host <box>                    # delivers orb repo, config, + per-machine agent files
ssh <box> 'cd ~/orb && ./setup.sh --config ~/config.toml'
```

`setup.sh` sources `orb-env.sh` itself per phase and (via `config/storage`) writes
`/etc/environment`, so no login shell is needed. Useful flags:

- `./setup.sh --list` — print the phases
- `./setup.sh --config ~/config.toml --only config/agent-env` — run one phase

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

### herdr integrations (pi / claude / codex)

`config/agent-env` runs `herdr integration install <agent>` for every installed agent (pi, claude,
codex) automatically — dropping each one's hook + settings so herdr sees agent session state. No
manual step, and it's self-idempotent (re-runs don't duplicate). For claude it runs after the
settings copy so the `SessionStart` hook lands in the freshly-installed settings. Each hook exits
cleanly outside a herdr pane, so it's harmless when herdr isn't running; if `herdr` isn't on the
box, agent-env warns and skips.

## 5. Validate

```
ssh <box> 'claude plugin list'          # plugins installed + enabled
ssh <box> 'claude mcp list'             # MCP servers connected/authenticated
ssh <box> 'claude -p "list your skills"'
ssh <box> 'pi -p "list your skills"'
ssh <box> 'herdr integration status'    # pi/claude/codex should show "current"
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
