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

echo "cli dispatch tests passed"
