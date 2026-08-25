# shellcheck shell=bash
# Install + enable the systemd unit(s) for the feedback-loop service (replaces the Mac's
# launchd feedback-loop agent). Templates in systemd/ carry @@PLACEHOLDER@@ tokens
# rendered here with the resolved paths, so a future VM with a different mount still works.
# daemon-reload + enable only when a unit actually changed (idempotent).
section "systemd services"
require_root

RENDER_DIR="$(mktemp -d)"
changed=0

render_unit() {
  # render_unit <template-basename>
  local name="$1" src="${SRA_SETUP_ROOT}/systemd/$1" dst="/etc/systemd/system/$1"
  sed \
    -e "s#@@REPO_DIR@@#${SRA_REPO_DIR}#g" \
    -e "s#@@ENV_FILE@@#${SRA_DATA_MOUNT}/secrets/feedback-loop.env#g" \
    -e "s#@@RUN_USER@@#${SRA_TARGET_USER}#g" \
    -e "s#@@TARGET_HOME@@#${SRA_TARGET_HOME}#g" \
    -e "s#@@LOG_DIR@@#${SRA_DATA_MOUNT}/logs#g" \
    "$src" >"${RENDER_DIR}/${name}"
  if [ ! -f "$dst" ] || ! cmp -s "${RENDER_DIR}/${name}" "$dst"; then
    install -m 0644 "${RENDER_DIR}/${name}" "$dst"
    changed=1
    ok "installed ${dst}"
  else
    ok "${name} unchanged"
  fi
}

render_unit sra-feedback-loop.service
render_unit sra-feedback-loop.timer
rm -rf "$RENDER_DIR"

if [ "$changed" -eq 1 ]; then
  systemctl daemon-reload
  ok "daemon-reload"
fi

# Enable the TIMER (not the service directly — the service is a oneshot the timer fires).
systemctl enable --now sra-feedback-loop.timer
ok "sra-feedback-loop.timer enabled ($(systemctl is-active sra-feedback-loop.timer 2>/dev/null))"