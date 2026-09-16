#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/cli_dispatch.sh
source "${ROOT}/scripts/cli_dispatch.sh"

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT

cat > "${TMPDIR_TEST}/mock-cli" <<'MOCK'
#!/usr/bin/env bash
printf 'arg=<%s>\n' "$@"
if [[ ! -t 0 ]]; then
    while IFS= read -r line; do
        printf 'stdin=<%s>\n' "${line}"
    done
fi
MOCK
chmod +x "${TMPDIR_TEST}/mock-cli"

cat > "${TMPDIR_TEST}/triage.toml" <<TOML
[cli_chain]
engineer = ["custom agent", "kiro"]

[cli_tools."custom agent"]
command = "${TMPDIR_TEST}/mock-cli"
args = ["run", "--workspace", "{worktree}", "value with spaces"]
prompt_mode = "stdin"

[cli_tools.kiro]
command = "${TMPDIR_TEST}/mock-cli"
args = ["chat", "--no-interactive", "--trust-all-tools"]
prompt_mode = "arg"
TOML

load_cli_chain "${TMPDIR_TEST}/triage.toml" engineer fallback
[[ "${CLI_CHAIN[*]}" == "custom agent kiro" ]]

WORKTREE="${TMPDIR_TEST}/work tree"
OUTPUT="${TMPDIR_TEST}/output"
run_cli_tool "${TMPDIR_TEST}/triage.toml" "custom agent" "${WORKTREE}" "prompt text" "${OUTPUT}"
grep -Fx 'arg=<run>' "${OUTPUT}"
grep -Fx 'arg=<--workspace>' "${OUTPUT}"
grep -Fx "arg=<${WORKTREE}>" "${OUTPUT}"
grep -Fx 'arg=<value with spaces>' "${OUTPUT}"
grep -Fx 'stdin=<prompt text>' "${OUTPUT}"

run_cli_tool "${TMPDIR_TEST}/triage.toml" kiro "${WORKTREE}" "prompt as argument" "${OUTPUT}"
grep -Fx 'arg=<chat>' "${OUTPUT}"
grep -Fx 'arg=<--no-interactive>' "${OUTPUT}"
grep -Fx 'arg=<--trust-all-tools>' "${OUTPUT}"
grep -Fx 'arg=<prompt as argument>' "${OUTPUT}"
if grep -q '^stdin=' "${OUTPUT}"; then
    echo "arg prompt unexpectedly sent via stdin" >&2
    exit 1
fi

load_cli_command /nonexistent kiro "${WORKTREE}"
[[ "${CLI_PROMPT_MODE}" == "arg" ]]
[[ "${CLI_COMMAND[*]}" == "kiro-cli chat --no-interactive --trust-all-tools" ]]

cat > "${TMPDIR_TEST}/failing-cli" <<'MOCK'
#!/usr/bin/env bash
exit 42
MOCK
chmod +x "${TMPDIR_TEST}/failing-cli"
cat >> "${TMPDIR_TEST}/triage.toml" <<TOML

[cli_tools.failing]
command = "${TMPDIR_TEST}/failing-cli"
TOML
if run_cli_tool "${TMPDIR_TEST}/triage.toml" failing "${WORKTREE}" "prompt" "${OUTPUT}"; then
    echo "failing CLI unexpectedly succeeded" >&2
    exit 1
else
    [[ $? -eq 42 ]]
fi

for message in \
    'Authentication required: run gh auth login' \
    'OAuth token expired' \
    'API key is invalid' \
    'HTTP 401 Unauthorized' \
    'Credit balance is too low' \
    'Error: claude native binary not installed.' \
    'platform-native optional dependency was not downloaded' \
    'quota exceeded'; do
    printf '%s\n' "${message}" > "${OUTPUT}"
    cli_error_allows_fallback "${OUTPUT}"
done

for message in \
    'authorization tests failed' \
    'permission check failed for the generated file' \
    'the TLS certificate expired yesterday' \
    'task failed with exit status 1'; do
    printf '%s\n' "${message}" > "${OUTPUT}"
    if cli_error_allows_fallback "${OUTPUT}"; then
        echo "task failure incorrectly allowed fallback: ${message}" >&2
        exit 1
    fi
done

# agy takes the prompt as the value of --print, so it must be the last argument.
load_cli_command /nonexistent agy "${WORKTREE}"
[[ "${CLI_PROMPT_MODE}" == "arg" ]]
[[ "${CLI_COMMAND[${#CLI_COMMAND[@]}-1]}" == "--print" ]]

# Quota and login failures park the CLI so queued items skip it until reset.
export TRIAGE_CLI_COOLDOWN_DIR="${TMPDIR_TEST}/cooldown"
cat > "${TMPDIR_TEST}/limited-cli" <<'MOCK'
#!/usr/bin/env bash
echo "${LIMIT_MESSAGE}"
exit 1
MOCK
chmod +x "${TMPDIR_TEST}/limited-cli"
cat >> "${TMPDIR_TEST}/triage.toml" <<TOML

[cli_tools.limited]
command = "${TMPDIR_TEST}/limited-cli"

[cli_tools.expired]
command = "${TMPDIR_TEST}/limited-cli"
TOML

LIMIT_MESSAGE="ERROR: You've hit your usage limit. Try again at $(LC_ALL=C date -v+2H '+%b %-dth, %Y %-I:%M %p' 2>/dev/null || LC_ALL=C date -d '+2 hours' '+%b %-dth, %Y %-I:%M %p')." \
    run_cli_tool "${TMPDIR_TEST}/triage.toml" limited "${WORKTREE}" "prompt" "${OUTPUT}" >/dev/null || true
remaining="$(cli_cooldown_remaining limited)"
(( remaining > 6600 && remaining <= 7260 ))

LIMIT_MESSAGE="Failed to authenticate: OAuth session expired and could not be refreshed" \
    run_cli_tool "${TMPDIR_TEST}/triage.toml" expired "${WORKTREE}" "prompt" "${OUTPUT}" >/dev/null || true
[[ "$(sed -n 2p "$(cli_cooldown_file expired)")" == "authentication" ]]

if cli_chain_available limited expired; then
    echo "fully parked chain reported as available" >&2
    exit 1
fi
cli_chain_available limited kiro

# A parked CLI is not executed and reports a fallback-eligible failure.
set +e
LIMIT_MESSAGE="must not run" run_cli_tool "${TMPDIR_TEST}/triage.toml" limited "${WORKTREE}" "prompt" "${OUTPUT}" >/dev/null
rc=$?
set -e
[[ "${rc}" -eq 75 ]]
if grep -q "must not run" "${OUTPUT}"; then
    echo "parked CLI was executed" >&2
    exit 1
fi
cli_error_allows_fallback "${OUTPUT}"

# Expired cooldowns are cleared; ordinary task failures never park a CLI.
printf '%s\nusage limit\n' "$(( $(date +%s) - 1 ))" > "$(cli_cooldown_file limited)"
cli_chain_available limited
[[ ! -e "$(cli_cooldown_file limited)" ]]
run_cli_tool "${TMPDIR_TEST}/triage.toml" failing "${WORKTREE}" "prompt" "${OUTPUT}" >/dev/null || true
[[ ! -e "$(cli_cooldown_file failing)" ]]

echo "cli dispatch tests passed"
