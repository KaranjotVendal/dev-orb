# sra-vm-infra

Infra + configuration for `sra-vm-box`, a reusable remote agent workstation (herdr +
Claude Code workers + the sold-rate-agent repo), reached over SSM.

Two cleanly separated layers:

- **Terraform** (`*.tf`) — provisions the bare VM only (instance, EBS data volume, IAM,
  security group, SSM parameter placeholders). It does NOT configure the box.
- **`setup.sh`** — turns the bare Ubuntu 24.04 box into the full agent environment. Runs
  post-boot over SSM/SSH, OUTSIDE the Terraform boundary. Idempotent and re-runnable.

## Layer 1 — Terraform (the bare VM)

Standalone Terraform, moved out of the sold-rate-agent app repo as of 2026-08-25. State
is LOCAL (`terraform.tfstate` in this dir); there is no remote backend.

Manages: EC2 instance `<INSTANCE_ID>` (`Name=sra-vm-box`), the durable EBS data
volume + attachment, the instance IAM role / profile / broker role, the security group
(no ingress), and the SSM SecureString parameter placeholders.

Account mlops (`<AWS_ACCOUNT_ID>`), region `eu-west-1`. Always run with the mlops profile:

```
AWS_PROFILE=mlops AWS_REGION=eu-west-1 terraform init
AWS_PROFILE=mlops AWS_REGION=eu-west-1 terraform plan
AWS_PROFILE=mlops AWS_REGION=eu-west-1 terraform apply
```

The instance is LIVE. Review every plan. Watch for any
`-/+ destroy and then create replacement` on `aws_instance.box` — that recreates the host.

NOTE (open, separate task): `terraform plan` currently shows a pre-existing `user_data`
drift that would REPLACE the instance (config edited Jul 30, last applied Jul 27).
Reconcile that before any apply. Do NOT `terraform apply` without operator sign-off.

## Layer 2 — setup.sh (the agent environment)

Structure (borrowed from omarchy: single entry, sourced helper libs, fail-closed
preflight, phased install):

```
setup.sh              entry point; sources lib, runs phases in order
lib/                  logging.sh (sectioned log -> /var/log/sra-setup.log), helpers.sh
preflight/guard.sh    fail-closed checks: Ubuntu 24.04, x86_64, user, /mnt/sra-data mounted, SSM reachable
packaging/            apt-base.packages (manifest) + apt.sh, mise.sh, agent-stack.sh
config/               storage.sh, secrets.sh, repo.sh
login/auth.sh         the one interactive step (claude login)
migrations/           timestamped one-offs, run once, sentinel-tracked
mise.toml             pinned: node 22, python 3.14, uv latest, pi (npm backend)
bin/                  sra-doctor (verify), sra-update (re-converge)
```

Phase order: `guard -> apt -> storage -> mise -> agents -> secrets -> repo` then
migrations, then the interactive `login` phase. There is no scheduled service on the box
(the feedback loop is run on demand, not by a timer).

What it installs: mise-managed node/python/uv; the agent stack (Claude Code, herdr, circli, gh;
pi comes from mise); base CLI utils (rg, fd, jq, unzip, build-essential, aws CLI v2). All heavy
trees (npm-global, caches, worktrees, the repo, the venv) are placed on `/mnt/sra-data`
via an env snippet, since root is only ~7 G. Docker and codex are intentionally NOT
installed.

Run it (as root, over the SSM session):

```
sudo ./setup.sh            # full run; the login phase is interactive
sudo ./setup.sh -y         # unattended: every phase except the interactive login
sudo ./setup.sh --only mise
sudo ./setup.sh --list
```

Re-run anytime to converge. `bin/sra-update` pulls this repo and re-runs `setup.sh -y`;
`bin/sra-doctor` prints a PASS/FAIL table of every tool + the mount/repo/login state.

## Configuration (per box)

MVF-specific values are not baked in — set them as environment variables when running
`setup.sh` (or export them in a local, uncommitted `sra.env` you `source` first):

| Variable | Purpose |
|---|---|
| `SRA_REPO_SLUG` | the sold-rate-agent repo to clone, e.g. `your-org/sold-rate-agent` (unset = repo phase skipped) |
| `SRA_REPO_BRANCH` | branch to check out (default `feat/wire-metrics`) |
| `SRA_GIT_EMAIL` / `SRA_GIT_NAME` | git identity for clone/commit (unset = identity phase skipped) |
| `SRA_FEEDBACK_LOOP_SLACK_CHANNEL` | Slack channel id for the digest |
| `SRA_BITBUCKET_ORG` | org for the optional circli/bbcli HTTPS clone |
| `SRA_SSM_PREFIX` | SSM subtree for this box's secrets (default `/sold-rate-agent/vm`) |
| `SRA_TARGET_USER` / `SRA_DATA_MOUNT` / `SRA_REGION` | run user, data mount, AWS region |

## End-to-end: spin a new VM

1. `terraform apply` (mlops profile) — provisions the bare box + data volume + IAM + SSM
   placeholders. Reconcile the user_data drift first (separate task).
2. Set the required SSM parameter values out of band (see table below) — the placeholders
   Terraform seeds must be overwritten with real values BEFORE `setup.sh` reads them.
3. Attach over SSM: `herdr --remote sra-fbl`, or an SSM session to the instance id.
4. Get `setup.sh` onto the box (clone this repo, or rsync it over the `sra-fbl` tunnel).
5. `sudo ./setup.sh -y` — the unattended phases.
6. `sudo ./setup.sh --only login` — the interactive `claude login` device-code step.
7. `sra-doctor` — confirm everything is green.
8. Run the feedback loop on demand from the repo (via `mise exec -- uv run ...`) or through
   a herdr session — the box runs no scheduled job.

## Required SSM parameters

All under the prefix `/sold-rate-agent/vm` (the instance role grants read on the whole
subtree). Values are pulled at runtime; nothing is baked into any committed file.

Already Terraform-managed (placeholders; set real values out of band):

| Parameter | Type | Used for |
|---|---|---|
| `/sold-rate-agent/vm/snowflake/private-key-b64` | SecureString | Snowflake key-pair auth (written to a 0600 file) |
| `/sold-rate-agent/vm/snowflake/identity` | String | non-secret SF_* connection block, appended to the loop env |
| `/sold-rate-agent/vm/slack/debug-webhook` | SecureString | DEBUG-only Slack webhook (existing codex run) |
| `/sold-rate-agent/vm/deploy/ssh-authorized-key` | String | authorized_keys for the deploy tunnel |
| `/sold-rate-agent/vm/snowflake/id-token` | SecureString | short-lived id-token (broker-pushed; legacy) |
| `/sold-rate-agent/vm/codex/seat-{1,2,3}` | SecureString | codex seat bundles (existing codex run) |

New parameters `setup.sh` reads (NOT yet in Terraform — create out of band, then fold
into `ssm.tf` as part of the drift-reconciliation task):

| Parameter | Type | Used for | If unset |
|---|---|---|---|
| `/sold-rate-agent/vm/github/token` | SecureString | `gh auth` -> clone/commit the repo | private clone/push fails |
| `/sold-rate-agent/vm/slack/bot-token` | SecureString | `SLACK_BOT_TOKEN` for the feedback loop digest | loop cannot post |
| `/sold-rate-agent/vm/circleci/token` | SecureString | circli auth (`CIRCLECI_TOKEN`) | circli unauthenticated |
| `/sold-rate-agent/vm/openrouter/api-key` | SecureString | `OPENROUTER_API_KEY` for the loop / pi | omitted from loop env |
| `/sold-rate-agent/vm/bitbucket/http-credential` | SecureString | HTTPS clone of circli + bbcli source (`user:app-password`) | circli skipped unless source is rsynced |

## Reach

SSH-over-SSM alias `sra-fbl` in `~/.ssh/config` (ProxyCommand via `aws ssm start-session`,
profile mlops). `herdr --remote sra-fbl` attaches once herdr is on the box.

## Open items (flagged for check-in)

- **circli source**: circli depends on bbcli via a sibling path (`../bbcli`); both are
  Bitbucket-SSH repos the VM has no key for. `setup.sh` resolves source by (1) already-
  present trees rsynced to `/mnt/sra-data/work/{circli,bbcli}`, else (2) HTTPS clone using
  the `bitbucket/http-credential` SSM param. Pick one.
- **circli auth**: circli's token is surfaced as `CIRCLECI_TOKEN`; on a headless box its
  keyring backend may still need `keyrings.alt`.
- **pi auth**: pi is installed via mise; authentication is handled out-of-band via codex
  device auth, not baked into setup.
- **gh-stack**: installs `github/gh-stack` by default (override `SRA_GHSTACK_REPO`).
