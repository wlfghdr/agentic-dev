#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT

TRIAGE_DIR="${TMPDIR_TEST}/triage&ops|prod%unit" \
TRIAGE_REPOS_DIR="${TMPDIR_TEST}/acme&partners/repos%unit" \
TRIAGE_WORKTREES_DIR="${TMPDIR_TEST}/acme|partners/work trees" \
bash -n "${ROOT}/install.sh"

render_helper="${TMPDIR_TEST}/render_template.sh"
sed -n '/^escape_sed_replacement()/,/^}/p; /^escape_systemd_replacement()/,/^}/p; /^render_template()/,/^}/p' "${ROOT}/install.sh" > "${render_helper}"
# shellcheck source=/dev/null
source "${render_helper}"

TRIAGE_DIR="${TMPDIR_TEST}/triage&ops|prod%unit"
TRIAGE_REPOS_DIR="${TMPDIR_TEST}/acme&partners/repos%unit"
TRIAGE_WORKTREES_DIR="${TMPDIR_TEST}/acme|partners/work trees"

template="${TMPDIR_TEST}/dispatch.conf.in"
rendered="${TMPDIR_TEST}/dispatch.conf"
cat > "${template}" <<'TEMPLATE'
Environment="TRIAGE_REPOS_DIR=@TRIAGE_REPOS_DIR@"
Environment="TRIAGE_WORKTREES_DIR=@TRIAGE_WORKTREES_DIR@"
Environment=TRIAGE_DIR=/srv/agentic-dev
TEMPLATE

render_template "${template}" "${rendered}"

systemd_triage_dir="${TRIAGE_DIR//%/%%}"
systemd_repos_dir="${TRIAGE_REPOS_DIR//%/%%}"
grep -Fx "Environment=\"TRIAGE_REPOS_DIR=${systemd_repos_dir}\"" "${rendered}"
grep -Fx "Environment=\"TRIAGE_WORKTREES_DIR=${TRIAGE_WORKTREES_DIR}\"" "${rendered}"
grep -Fx "Environment=TRIAGE_DIR=${systemd_triage_dir}" "${rendered}"

script_rendered="$(printf '/srv/agentic-dev/bin\n' | sed "s|/srv/agentic-dev|$(escape_sed_replacement "${TRIAGE_DIR}")|g")"
[[ "${script_rendered}" == "${TRIAGE_DIR}/bin" ]]

echo "install rendering tests passed"
