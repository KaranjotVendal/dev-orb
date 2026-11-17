#!/usr/bin/env bash
set -euo pipefail

# vm-power.sh — start, stop or check the box's EC2 instance from this Mac. The instance id is the
# SSH host's HostName (an SSM-style host), so nothing about the instance is stored here. Stopping
# keeps the disk (EBS); the box comes back with everything on it.

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
Usage: vm-power [--host <ssh_host>] [--config <path>] [--force] start|stop|status

Start, stop or check the box's EC2 instance from this Mac.

  status   Print the instance state (pending, running, stopping, stopped, ...).
  start    Start the instance, wait until it is running, then wait until SSH answers.
  stop     Stop the instance and wait until it is stopped. The disk (EBS) is kept.
           Refuses if the herdr app (hc) shows live terminals on the box, unless --force.

The instance id is read from `ssh -G <host>`: the host must be an SSM-style host whose
HostName is the instance id (i-...). The region is [box].region from the config; the AWS
profile is [box].aws_profile if set, else AWS_PROFILE / the default credentials.

  --host <ssh_host>   SSH host (default: [box].ssh_host from the config, else orb-vm)
  --config <path>     Path to the box config.toml (default: ~/.config/orb/config.toml)
  --force             stop even when live terminals are open on the box
  -h, --help          Show this help and exit
EOF
}

ssh_host=""
config_path="${HOME}/.config/orb/config.toml"
force=0
action=""

while [ $# -gt 0 ]; do
  case "$1" in
    --host)    ssh_host="$2"; shift 2 ;;
    --config)  config_path="$2"; shift 2 ;;
    --force)   force=1; shift ;;
    -h|--help) usage; exit 0 ;;
    start|stop|status)
      [ -z "$action" ] || die "only one action allowed (got ${action} and $1)"
      action="$1"; shift ;;
    *)         die "unknown argument: $1" ;;
  esac
done

[ -n "$action" ] || { usage >&2; die "missing action: start, stop or status"; }

# Preconditions.
have aws     || die "aws not found on PATH"
have ssh     || die "ssh not found on PATH"
have python3 || die "python3 not found on PATH"
[ -f "$config_path" ] || die "config not found: ${config_path}"

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
region="$(config_value ORB_BOX_REGION)"
aws_profile="$(config_value ORB_BOX_AWS_PROFILE)"

# The instance id is the host's resolved HostName (ssh -G prints it lowercased as `hostname`).
instance_id="$(ssh -G "$ssh_host" 2>/dev/null | awk '$1 == "hostname" { print $2; exit }')"
[[ "$instance_id" =~ ^i-[0-9a-f]+$ ]] \
  || die "${ssh_host}: HostName is '${instance_id}', not an instance id (i-...). vm-power needs an SSM-style SSH host whose HostName is the EC2 instance id."

aws_args=(--region "$region")
[ -n "$aws_profile" ] && aws_args+=(--profile "$aws_profile")

# instance_state — the instance's current state name (running, stopped, ...).
instance_state() {
  aws ec2 describe-instances "${aws_args[@]}" --instance-ids "$instance_id" \
    --query 'Reservations[0].Instances[0].State.Name' --output text
}

# live_box_terminals — print "address<TAB>agent<TAB>cwd" for each live hc terminal on the box.
# Remote terminals are addressed "<machine>/<id>". The hc machine is the one whose target is the
# SSH host (as bootstrap adds it); if none matches, the SSH host is used as the machine name.
# Prints nothing if hc is absent or its listing fails.
live_box_terminals() {
  have hc || return 0
  local machines terminals
  machines="$(hc machine ls --json 2>/dev/null)" || machines='{}'
  terminals="$(hc ls --json 2>/dev/null)" || return 0
  python3 -c '
import json, sys
host, machines, terminals = sys.argv[1], json.loads(sys.argv[2]), json.loads(sys.argv[3])
names = [machine["name"] for machine in machines.get("machines", []) if machine.get("target") == host]
machine_name = names[0] if names else host
for terminal in terminals.get("terminals", []):
    if terminal.get("state") == "live" and terminal.get("address", "").startswith(machine_name + "/"):
        print("\t".join([terminal["address"], terminal.get("agent", "?"), terminal.get("cwd", "?")]))
' "$ssh_host" "$machines" "$terminals" || true
}

# wait_for_ssh — retry `ssh true` until the box answers (the SSM agent needs a moment after boot).
wait_for_ssh() {
  local attempt
  for attempt in $(seq 1 18); do
    if ssh -n -o ConnectTimeout=10 "$ssh_host" true 2>/dev/null; then
      return 0
    fi
    step "ssh not answering yet (attempt ${attempt}/18); retrying in 10s"
    sleep 10
  done
  return 1
}

case "$action" in
  status)
    printf '%s\n' "$(instance_state)"
    ;;

  start)
    section "vm-power start ${ssh_host} (${instance_id})"
    state="$(instance_state)"
    if [ "$state" = "running" ]; then
      ok "${ssh_host} is already running"
      exit 0
    fi
    step "starting ${instance_id} (was ${state})"
    aws ec2 start-instances "${aws_args[@]}" --instance-ids "$instance_id" >/dev/null
    step "waiting for the instance to be running"
    aws ec2 wait instance-running "${aws_args[@]}" --instance-ids "$instance_id"
    step "waiting for ssh ${ssh_host}"
    wait_for_ssh || die "${ssh_host} is running but ssh did not answer within ~3 minutes"
    ok "${ssh_host} is up and reachable over ssh"
    ;;

  stop)
    section "vm-power stop ${ssh_host} (${instance_id})"
    state="$(instance_state)"
    if [ "$state" = "stopped" ]; then
      ok "${ssh_host} is already stopped"
      exit 0
    fi
    live_terminals="$(live_box_terminals)"
    if [ -n "$live_terminals" ]; then
      warn "live terminals on ${ssh_host}:"
      while IFS=$'\t' read -r terminal_address terminal_agent terminal_cwd; do
        warn "  ${terminal_address}  ${terminal_agent}  ${terminal_cwd}"
      done <<< "$live_terminals"
      [ "$force" -eq 1 ] || die "refusing to stop ${ssh_host} with live terminals; close them or pass --force"
      warn "--force given; stopping anyway"
    fi
    step "stopping ${instance_id} (was ${state})"
    aws ec2 stop-instances "${aws_args[@]}" --instance-ids "$instance_id" >/dev/null
    step "waiting for the instance to be stopped"
    aws ec2 wait instance-stopped "${aws_args[@]}" --instance-ids "$instance_id"
    ok "${ssh_host} is stopped (disk kept)"
    ;;
esac
