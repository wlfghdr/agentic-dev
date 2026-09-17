#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

RUNTIME="${TEST_ROOT}/runtime"
mkdir -p "${RUNTIME}/bin" "${RUNTIME}/state" "${RUNTIME}/logs" "${TEST_ROOT}/mock-bin"
install -m 0755 "${ROOT}/scripts/tick.sh" "${RUNTIME}/bin/tick.sh"
install -m 0755 "${ROOT}/scripts/parse_toml.py" "${RUNTIME}/bin/parse_toml.py"

cat > "${RUNTIME}/bin/detect.py" <<'MOCK'
#!/usr/bin/env bash
cat <<'JSON'
{"itemCount":1,"liveLockSlugs":[],"items":[{"kind":"engineer","mode":"issue","repo":"acme/app","number":7,"title":"test","url":"https://example.invalid/7"}]}
JSON
MOCK

cat > "${RUNTIME}/bin/engineer.sh" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

cat > "${TEST_ROOT}/mock-bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
[[ "${1:-}" == "list-units" ]] && exit 0
exit 0
MOCK

cat > "${TEST_ROOT}/mock-bin/systemd-run" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${SYSTEMD_RUN_ARGS}"
[[ "${FAIL_SYSTEMD_RUN:-0}" != "1" ]]
MOCK
chmod +x "${RUNTIME}/bin/"* "${TEST_ROOT}/mock-bin/"*

cat > "${RUNTIME}/triage.toml" <<TOML
[limits]
max_engineer = 1

[runtime]
dispatch_env_file = "${TEST_ROOT}/dispatch.env"
TOML

SYSTEMD_RUN_ARGS="${TEST_ROOT}/systemd-run.args" \
PATH="${TEST_ROOT}/mock-bin:${PATH}" \
TRIAGE_DIR="${RUNTIME}" \
TRIAGE_CONFIG="${RUNTIME}/triage.toml" \
TRIAGE_ENABLE_DISPATCH=1 \
"${RUNTIME}/bin/tick.sh" >/dev/null

if ! grep -Fx -- "--property=EnvironmentFile=-${TEST_ROOT}/dispatch.env" "${TEST_ROOT}/systemd-run.args"; then
    echo "dispatch did not forward the configured environment file" >&2
    sed -n '1,120p' "${TEST_ROOT}/systemd-run.args" >&2
    exit 1
fi

# A dispatcher creation failure must not strand the item lock.
rm -f "${RUNTIME}/state/locks/engineer-acme_app-7.lock"
FAIL_SYSTEMD_RUN=1 \
SYSTEMD_RUN_ARGS="${TEST_ROOT}/systemd-run-failed.args" \
PATH="${TEST_ROOT}/mock-bin:${PATH}" \
TRIAGE_DIR="${RUNTIME}" \
TRIAGE_CONFIG="${RUNTIME}/triage.toml" \
TRIAGE_ENABLE_DISPATCH=1 \
"${RUNTIME}/bin/tick.sh" >/dev/null
[[ ! -e "${RUNTIME}/state/locks/engineer-acme_app-7.lock" ]]

# Idle ticks leave no per-minute log file; dispatching ticks keep theirs.
[[ "$(find "${RUNTIME}/logs" -name '*-tick.log' | wc -l)" -ge 1 ]]
rm -f "${RUNTIME}/logs/"*-tick.log
cat > "${RUNTIME}/bin/detect.py" <<'MOCK'
#!/usr/bin/env bash
echo '{"itemCount":0,"liveLockSlugs":[],"items":[]}'
MOCK
PATH="${TEST_ROOT}/mock-bin:${PATH}" \
TRIAGE_DIR="${RUNTIME}" \
TRIAGE_CONFIG="${RUNTIME}/triage.toml" \
TRIAGE_ENABLE_DISPATCH=1 \
"${RUNTIME}/bin/tick.sh" >/dev/null 2>&1
[[ "$(find "${RUNTIME}/logs" -name '*-tick.log' | wc -l)" -eq 0 ]]

# When every CLI in the chain is parked, the item is skipped without a lock
# or a dispatcher that could only fail.
install -m 0755 "${ROOT}/scripts/cli_dispatch.sh" "${RUNTIME}/bin/cli_dispatch.sh"
cat > "${RUNTIME}/bin/detect.py" <<'MOCK'
#!/usr/bin/env bash
cat <<'JSON'
{"itemCount":1,"liveLockSlugs":[],"items":[{"kind":"review","mode":"pr","repo":"acme/app","number":8,"title":"test","url":"https://example.invalid/8"}]}
JSON
MOCK
cat >> "${RUNTIME}/triage.toml" <<'TOML'

[cli_chain]
review = ["claude", "codex"]
TOML
mkdir -p "${RUNTIME}/state/cli-cooldown"
for tool in claude codex; do
    printf '%s\nusage limit\n' "$(( $(date +%s) + 600 ))" > "${RUNTIME}/state/cli-cooldown/${tool}"
done
rm -f "${TEST_ROOT}/systemd-run-parked.args"
SYSTEMD_RUN_ARGS="${TEST_ROOT}/systemd-run-parked.args" \
PATH="${TEST_ROOT}/mock-bin:${PATH}" \
TRIAGE_DIR="${RUNTIME}" \
TRIAGE_CONFIG="${RUNTIME}/triage.toml" \
TRIAGE_ENABLE_DISPATCH=1 \
"${RUNTIME}/bin/tick.sh" > "${TEST_ROOT}/parked.out" 2>&1
grep -F "every review CLI is parked" "${TEST_ROOT}/parked.out"
[[ ! -e "${TEST_ROOT}/systemd-run-parked.args" ]]
[[ ! -e "${RUNTIME}/state/locks/review-acme_app-8.lock" ]]

rm -f "${RUNTIME}/state/cli-cooldown/codex"
SYSTEMD_RUN_ARGS="${TEST_ROOT}/systemd-run-parked.args" \
PATH="${TEST_ROOT}/mock-bin:${PATH}" \
TRIAGE_DIR="${RUNTIME}" \
TRIAGE_CONFIG="${RUNTIME}/triage.toml" \
TRIAGE_ENABLE_DISPATCH=1 \
"${RUNTIME}/bin/tick.sh" >/dev/null 2>&1
[[ -e "${TEST_ROOT}/systemd-run-parked.args" ]]

# Configuration is never evaluated as arithmetic by the root-owned tick.
PATH="${TEST_ROOT}/mock-bin:${PATH}" \
TRIAGE_DIR="${RUNTIME}" \
TRIAGE_CONFIG="${RUNTIME}/triage.toml" \
TRIAGE_ENABLE_DISPATCH=1 \
TRIAGE_WORKTREE_GC_HOURS='a[$(touch "'"${TEST_ROOT}"'/injected")]' \
"${RUNTIME}/bin/tick.sh" > "${TEST_ROOT}/injection.out" 2>&1
[[ ! -e "${TEST_ROOT}/injected" ]]
grep -F "ignoring invalid TRIAGE_WORKTREE_GC_HOURS" "${TEST_ROOT}/injection.out"

cat > "${RUNTIME}/triage.toml" <<'TOML'
[runtime]
dispatch_env_file = "relative/dispatch.env"
TOML

if PATH="${TEST_ROOT}/mock-bin:${PATH}" \
    TRIAGE_DIR="${RUNTIME}" \
    TRIAGE_CONFIG="${RUNTIME}/triage.toml" \
    "${RUNTIME}/bin/tick.sh" >"${TEST_ROOT}/invalid.out" 2>&1; then
    echo "relative runtime.dispatch_env_file unexpectedly accepted" >&2
    exit 1
fi
grep -F "must be an absolute path" "${TEST_ROOT}/invalid.out"

echo "tick dispatch tests passed"
