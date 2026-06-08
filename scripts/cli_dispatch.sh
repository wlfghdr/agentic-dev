#!/usr/bin/env bash
# Shared CLI-chain configuration and execution helpers.

load_cli_chain() {
    # load_cli_chain CONFIG CHAIN_NAME DEFAULT_TOOL...
    local config="${1}"
    local chain_name="${2}"
    shift 2

    CLI_CHAIN=()
    if [[ -f "${config}" ]]; then
        mapfile -d '' -t CLI_CHAIN < <(
            python3 - "${config}" "${chain_name}" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as config_file:
    config = tomllib.load(config_file)

for tool in config.get("cli_chain", {}).get(sys.argv[2], []):
    if isinstance(tool, str):
        print(tool, end="\0")
PY
        )
    fi

    if [[ ${#CLI_CHAIN[@]} -eq 0 ]]; then
        CLI_CHAIN=("$@")
    fi
}

load_cli_command() {
    # load_cli_command CONFIG TOOL WORKTREE
    local config="${1}"
    local tool="${2}"
    local worktree="${3}"

    CLI_COMMAND=()
    CLI_PROMPT_MODE=""
    mapfile -d '' -t CLI_COMMAND < <(
        python3 - "${config}" "${tool}" "${worktree}" <<'PY'
import os
import sys
import tomllib

config_path, tool, worktree = sys.argv[1:]
defaults = {
    "codex": {
        "command": "codex",
        "args": [
            "exec",
            "--dangerously-bypass-approvals-and-sandbox",
            "--cd",
            "{worktree}",
            "-",
        ],
        "prompt_mode": "stdin",
    },
    "claude": {
        "command": "claude",
        "args": ["-p", "--add-dir", "{worktree}"],
        "prompt_mode": "stdin",
    },
    "agy": {
        "command": "agy",
        "args": [
            "--print",
            "--dangerously-skip-permissions",
            "--add-dir",
            "{worktree}",
        ],
        "prompt_mode": "stdin",
    },
    "kiro": {
        "command": "kiro-cli",
        "args": ["chat", "--no-interactive", "--trust-all-tools"],
        "prompt_mode": "arg",
    },
}

configured = {}
if os.path.isfile(config_path):
    with open(config_path, "rb") as config_file:
        configured = tomllib.load(config_file).get("cli_tools", {}).get(tool, {})

definition = defaults.get(tool, {}) | configured
command = definition.get("command", tool)
args = definition.get("args", [])
prompt_mode = definition.get("prompt_mode", "stdin")

if not isinstance(command, str) or not command:
    raise SystemExit(f"cli_tools.{tool}.command must be a non-empty string")
if not isinstance(args, list) or not all(isinstance(arg, str) for arg in args):
    raise SystemExit(f"cli_tools.{tool}.args must be an array of strings")
if prompt_mode not in {"stdin", "arg"}:
    raise SystemExit(f"cli_tools.{tool}.prompt_mode must be 'stdin' or 'arg'")

values = [prompt_mode, command]
values.extend(arg.replace("{worktree}", worktree) for arg in args)
for value in values:
    print(value, end="\0")
PY
    )

    if [[ ${#CLI_COMMAND[@]} -lt 2 ]]; then
        echo "ERROR: failed to load CLI definition for ${tool}" >&2
        return 2
    fi

    CLI_PROMPT_MODE="${CLI_COMMAND[0]}"
    CLI_COMMAND=("${CLI_COMMAND[@]:1}")
}

run_cli_tool() {
    # run_cli_tool CONFIG TOOL WORKTREE PROMPT OUTPUT_FILE
    local config="${1}"
    local tool="${2}"
    local worktree="${3}"
    local prompt="${4}"
    local output_file="${5}"
    local rc

    load_cli_command "${config}" "${tool}" "${worktree}" || return $?

    set +e
    if [[ "${CLI_PROMPT_MODE}" == "arg" ]]; then
        "${CLI_COMMAND[@]}" "${prompt}" 2>&1 | tee "${output_file}"
        rc=${PIPESTATUS[0]}
    else
        printf '%s\n' "${prompt}" | "${CLI_COMMAND[@]}" 2>&1 | tee "${output_file}"
        rc=${PIPESTATUS[1]}
    fi
    set -e
    return "${rc}"
}
