# shellcheck shell=bash
# Print the resolved configuration before acting, so a run is auditable and a mispointed
# override (wrong user, wrong branch, wrong SSM prefix) is caught by eye. Sourced by the
# guard phase is optional; setup.sh does not run it by default — invoke via --only.

section "resolved environment"
step "target user     : ${SRA_TARGET_USER} (home ${SRA_TARGET_HOME})"
step "data mount      : ${SRA_DATA_MOUNT}"
step "aws region      : ${SRA_REGION}"
step "ssm prefix      : ${SRA_SSM_PREFIX}"
step "repo            : ${SRA_REPO_SLUG} @ ${SRA_REPO_BRANCH}"
step "repo dir        : ${SRA_REPO_DIR}"
step "git identity    : ${SRA_GIT_NAME} <${SRA_GIT_EMAIL}>"
step "log file        : ${SRA_LOG_FILE}"