#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT

TRIAGE_DIR="${TMPDIR_TEST}/triage" \
TRIAGE_REPOS_DIR="${TMPDIR_TEST}/acme&partners/repos" \
TRIAGE_WORKTREES_DIR="${TMPDIR_TEST}/acme|partners/work trees" \
bash -n "${ROOT}/install.sh"

source_lines=$(sed -n '/^render_template()/,/^}/p' "${ROOT}/install.sh")
eval "${source_lines}"

TRIAGE_DIR="${TMPDIR_TEST}/triage"
TRIAGE_REPOS_DIR="${TMPDIR_TEST}/acme&partners/repos"
TRIAGE_WORKTREES_DIR="${TMPDIR_TEST}/acme|partners/work trees"

template="${TMPDIR_TEST}/dispatch.conf.in"
rendered="${TMPDIR_TEST}/dispatch.conf"
cat > "${template}" <<'TEMPLATE'
Environment=TRIAGE_REPOS_DIR=@TRIAGE_REPOS_DIR@
Environment=TRIAGE_WORKTREES_DIR=@TRIAGE_WORKTREES_DIR@
Environment=TRIAGE_DIR=/srv/agentic-dev
TEMPLATE

render_template "${template}" "${rendered}"

grep -Fx "Environment=TRIAGE_REPOS_DIR=${TRIAGE_REPOS_DIR}" "${rendered}"
grep -Fx "Environment=TRIAGE_WORKTREES_DIR=${TRIAGE_WORKTREES_DIR}" "${rendered}"
grep -Fx "Environment=TRIAGE_DIR=${TRIAGE_DIR}" "${rendered}"

echo "install rendering tests passed"
