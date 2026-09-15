#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT

TRIAGE_DIR="${TMPDIR_TEST}/triage&ops|prod%unit\"quote\\slash" \
TRIAGE_REPOS_DIR="${TMPDIR_TEST}/acme&partners/repos%unit\"quote\\slash" \
TRIAGE_WORKTREES_DIR="${TMPDIR_TEST}/acme|partners/work trees\"quote\\slash" \
bash -n "${ROOT}/install.sh"

render_helper="${TMPDIR_TEST}/render_template.sh"
sed -n '/^escape_sed_replacement()/,/^}/p; /^escape_systemd_value()/,/^}/p; /^escape_systemd_replacement()/,/^}/p; /^render_template()/,/^}/p' "${ROOT}/install.sh" > "${render_helper}"
# shellcheck source=/dev/null
source "${render_helper}"

# Production installs must not derive these paths from /srv/agentic-dev: the
# triage host keeps repositories and worktrees below /srv/wulfai.
grep -Fq 'TRIAGE_REPOS_DIR="${TRIAGE_REPOS_DIR:-/srv/wulfai/repos}"' "${ROOT}/install.sh"
grep -Fq 'TRIAGE_WORKTREES_DIR="${TRIAGE_WORKTREES_DIR:-/srv/wulfai/worktrees}"' "${ROOT}/install.sh"

TRIAGE_DIR="${TMPDIR_TEST}/triage&ops|prod%unit\"quote\\slash"
TRIAGE_REPOS_DIR="${TMPDIR_TEST}/acme&partners/repos%unit\"quote\\slash"
TRIAGE_WORKTREES_DIR="${TMPDIR_TEST}/acme|partners/work trees\"quote\\slash"

template="${TMPDIR_TEST}/dispatch.conf.in"
rendered="${TMPDIR_TEST}/dispatch.conf"
cat > "${template}" <<'TEMPLATE'
Environment="TRIAGE_REPOS_DIR=@TRIAGE_REPOS_DIR@"
Environment="TRIAGE_WORKTREES_DIR=@TRIAGE_WORKTREES_DIR@"
Environment=TRIAGE_DIR=/srv/agentic-dev
TEMPLATE

render_template "${template}" "${rendered}"

systemd_triage_dir="$(escape_systemd_value "${TRIAGE_DIR}")"
systemd_repos_dir="$(escape_systemd_value "${TRIAGE_REPOS_DIR}")"
systemd_worktrees_dir="$(escape_systemd_value "${TRIAGE_WORKTREES_DIR}")"
grep -Fx "Environment=\"TRIAGE_REPOS_DIR=${systemd_repos_dir}\"" "${rendered}"
grep -Fx "Environment=\"TRIAGE_WORKTREES_DIR=${systemd_worktrees_dir}\"" "${rendered}"
grep -Fx "Environment=TRIAGE_DIR=${systemd_triage_dir}" "${rendered}"

script_rendered="$(printf '/srv/agentic-dev/bin\n' | sed "s|/srv/agentic-dev|$(escape_sed_replacement "${TRIAGE_DIR}")|g")"
[[ "${script_rendered}" == "${TRIAGE_DIR}/bin" ]]

# Exercise the real installer without root or host mutations. A second install
# must preserve the instance-specific configuration.
SANDBOX_RUNTIME="${TMPDIR_TEST}/sandbox/runtime"
SANDBOX_SYSTEMD="${TMPDIR_TEST}/sandbox/systemd"
SANDBOX_LOGROTATE="${TMPDIR_TEST}/sandbox/logrotate"
TRIAGE_DIR="${SANDBOX_RUNTIME}" \
TRIAGE_REPOS_DIR="${TMPDIR_TEST}/sandbox/repos" \
TRIAGE_WORKTREES_DIR="${TMPDIR_TEST}/sandbox/worktrees" \
TRIAGE_SYSTEMD_DIR="${SANDBOX_SYSTEMD}" \
TRIAGE_LOGROTATE_DIR="${SANDBOX_LOGROTATE}" \
TRIAGE_SKIP_SYSTEMD=1 \
"${ROOT}/install.sh" >/dev/null

cat > "${SANDBOX_RUNTIME}/triage.toml" <<'TOML'
[agent]
login = "instance-agent"

[runtime]
dispatch_env_file = "/etc/example/dispatch.env"
TOML

TRIAGE_DIR="${SANDBOX_RUNTIME}" \
TRIAGE_REPOS_DIR="${TMPDIR_TEST}/sandbox/repos" \
TRIAGE_WORKTREES_DIR="${TMPDIR_TEST}/sandbox/worktrees" \
TRIAGE_SYSTEMD_DIR="${SANDBOX_SYSTEMD}" \
TRIAGE_LOGROTATE_DIR="${SANDBOX_LOGROTATE}" \
TRIAGE_SKIP_SYSTEMD=1 \
"${ROOT}/install.sh" >/dev/null

grep -Fq 'login = "instance-agent"' "${SANDBOX_RUNTIME}/triage.toml"
grep -Fq 'dispatch_env_file = "/etc/example/dispatch.env"' "${SANDBOX_RUNTIME}/triage.toml"
grep -Fq "ExecStart=${SANDBOX_RUNTIME}/bin/tick.sh" "${SANDBOX_SYSTEMD}/triage-tick.service"
grep -Fq "${SANDBOX_RUNTIME}/logs/*.log" "${SANDBOX_LOGROTATE}/agentic-triage"

if TRIAGE_SKIP_SYSTEMD=1 TRIAGE_DIR="${TMPDIR_TEST}/unsafe-sandbox" "${ROOT}/install.sh" >/dev/null 2>&1; then
    echo "sandbox install accepted live host integration targets" >&2
    exit 1
fi

echo "install rendering tests passed"
