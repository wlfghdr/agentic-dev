#!/usr/bin/env bash
# Shared CLI-chain configuration and execution helpers.

load_cli_chain() {
    # load_cli_chain CONFIG CHAIN_NAME DEFAULT_TOOL...
    local config="${1}"
    local chain_name="${2}"
    shift 2

    local py_code
    py_code='import sys
try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib
    except ImportError:
        tomllib = None

if tomllib:
    with open(sys.argv[1], "rb") as config_file:
        config = tomllib.load(config_file)
else:
    import re
    config = {}
    current_section = None
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            section_match = re.match(r"^\[([^\]]+)\]$", line)
            if section_match:
                sect_name = section_match.group(1)
                parts = [p.strip("\"\x27") for p in sect_name.split(".")]
                curr = config
                for p in parts[:-1]:
                    curr = curr.setdefault(p, {})
                current_section = curr.setdefault(parts[-1], {})
                continue
            kv_match = re.match(r"^([a-zA-Z0-9_\-]+)\s*=\s*(.+)$", line)
            if kv_match and current_section is not None:
                key, val = kv_match.group(1), kv_match.group(2).strip()
                if "#" in val:
                    val = val.split("#", 1)[0].strip()
                if val.startswith("[") and val.endswith("]"):
                    config_val = [x.strip("\"\x27") for x in re.findall(r"\"([^\"]*)\"", val)]
                elif val.startswith("\"") and val.endswith("\""):
                    config_val = val[1:-1]
                else:
                    config_val = val
                current_section[key] = config_val

for tool in config.get("cli_chain", {}).get(sys.argv[2], []):
    if isinstance(tool, str):
        print(tool, end="\x00")'

    CLI_CHAIN=()
    if [[ -f "${config}" ]]; then
        while IFS= read -r -d '' item; do
            CLI_CHAIN+=("$item")
        done < <(python3 -c "${py_code}" "${config}" "${chain_name}")
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

    local py_code
    py_code='import os
import sys
try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib
    except ImportError:
        tomllib = None

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
        # --print takes the prompt as its value, so it must come last in arg
        # mode; the default 5m print timeout is too short for engineering runs.
        "args": [
            "--dangerously-skip-permissions",
            "--add-dir",
            "{worktree}",
            "--print-timeout",
            "60m",
            "--print",
        ],
        "prompt_mode": "arg",
    },
    "kiro": {
        "command": "kiro-cli",
        "args": ["chat", "--no-interactive", "--trust-all-tools"],
        "prompt_mode": "arg",
    },
}

configured = {}
if os.path.isfile(config_path):
    if tomllib:
        with open(config_path, "rb") as config_file:
            configured = tomllib.load(config_file).get("cli_tools", {}).get(tool, {})
    else:
        import re
        config = {}
        current_section = None
        with open(config_path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                section_match = re.match(r"^\[([^\]]+)\]$", line)
                if section_match:
                    sect = section_match.group(1)
                    parts = [p.strip("\"\x27") for p in sect.split(".")]
                    curr = config
                    for p in parts[:-1]:
                        curr = curr.setdefault(p, {})
                    current_section = curr.setdefault(parts[-1], {})
                    continue
                kv_match = re.match(r"^([a-zA-Z0-9_\-]+)\s*=\s*(.+)$", line)
                if kv_match and current_section is not None:
                    key, val = kv_match.group(1), kv_match.group(2).strip()
                    if "#" in val:
                        val = val.split("#", 1)[0].strip()
                    if val.startswith("[") and val.endswith("]"):
                        config_val = [x.strip("\"\x27") for x in re.findall(r"\"([^\"]*)\"", val)]
                    elif val.startswith("\"") and val.endswith("\""):
                        config_val = val[1:-1]
                    else:
                        config_val = val
                    current_section[key] = config_val
        configured = config.get("cli_tools", {}).get(tool, {})

definition = defaults.get(tool, {}).copy()
definition.update(configured)
command = definition.get("command", tool)
args = definition.get("args", [])
prompt_mode = definition.get("prompt_mode", "stdin")

if not isinstance(command, str) or not command:
    raise SystemExit(f"cli_tools.{tool}.command must be a non-empty string")
if not isinstance(args, list) or not all(isinstance(arg, str) for arg in args):
    raise SystemExit(f"cli_tools.{tool}.args must be an array of strings")
if prompt_mode not in ["stdin", "arg"]:
    raise SystemExit(f"cli_tools.{tool}.prompt_mode must be \"stdin\" or \"arg\"")

values = [prompt_mode, command]
values.extend(arg.replace("{worktree}", worktree) for arg in args)
for value in values:
    print(value, end="\x00")'

    CLI_COMMAND=()
    CLI_PROMPT_MODE=""
    while IFS= read -r -d '' item; do
        CLI_COMMAND+=("$item")
    done < <(python3 -c "${py_code}" "${config}" "${tool}" "${worktree}")

    if [[ ${#CLI_COMMAND[@]} -lt 2 ]]; then
        echo "ERROR: failed to load CLI definition for ${tool}" >&2
        return 2
    fi

    CLI_PROMPT_MODE="${CLI_COMMAND[0]}"
    CLI_COMMAND=("${CLI_COMMAND[@]:1}")
}

cli_cooldown_file() {
    local dir="${TRIAGE_CLI_COOLDOWN_DIR:-${TRIAGE_STATE_DIR:-${TRIAGE_DIR:-/srv/agentic-dev}/state}/cli-cooldown}"
    printf '%s/%s\n' "${dir}" "${1//[^A-Za-z0-9._-]/_}"
}

cli_cooldown_remaining() {
    # cli_cooldown_remaining TOOL — prints remaining seconds; fails if not cooling.
    local file until now
    file="$(cli_cooldown_file "${1}")"
    [[ -f "${file}" ]] || return 1
    until="$(head -n 1 "${file}" 2>/dev/null || true)"
    [[ "${until}" =~ ^[0-9]+$ ]] || return 1
    now="$(date +%s)"
    if (( until <= now )); then
        rm -f "${file}"
        return 1
    fi
    echo $(( until - now ))
}

cli_chain_available() {
    # cli_chain_available TOOL... — succeeds if any tool is not cooling down.
    local tool
    for tool in "$@"; do
        cli_cooldown_remaining "${tool}" >/dev/null || return 0
    done
    return 1
}

cli_record_cooldown() {
    # cli_record_cooldown TOOL OUTPUT_FILE RC
    # Quota and login failures do not heal within one backoff window. Parking
    # the CLI keeps every queued item from re-running its prompt against it.
    local tool="${1}" output_file="${2}" rc="${3}" tail_text seconds reason file until
    tail_text="$(tail -n 40 "${output_file}" 2>/dev/null || true)"
    # Only the wrapper's own 127 or a CLI startup diagnostic means "not installed";
    # a failing task command in the transcript does not.
    if [[ "${rc}" -eq 127 ]] || grep -Eqi 'native binary not installed|postinstall did not run|optional dependency was not downloaded' <<<"${tail_text}"; then
        seconds="${TRIAGE_CLI_MISSING_COOLDOWN_SECONDS:-3600}"
        reason="not installed"
    elif grep -Eqi 'authentication (failed|required|error)|failed to authenticate|oauth[^[:alnum:]]*(session|token)?[^[:alnum:]]*(failed|invalid|expired|required|error)|not logged in|login required|please (log|sign) in|(^|[^[:digit:]])401[^[:alnum:]]+unauthorized' <<<"${tail_text}"; then
        seconds="${TRIAGE_CLI_AUTH_COOLDOWN_SECONDS:-3600}"
        reason="authentication"
    elif grep -Eqi 'usage limit|rate[ -]?limit|quota|credit balance|insufficient credits|too many requests|(^|[^[:digit:]])429([^[:digit:]]|$)|overloaded|try again at' <<<"${tail_text}"; then
        seconds="${TRIAGE_CLI_LIMIT_COOLDOWN_SECONDS:-900}"
        reason="usage limit"
        # Honor an explicit reset time such as "try again at Sep 21st, 2026 10:47 PM".
        local reset
        reset="$(python3 - "${tail_text}" <<'PY' 2>/dev/null || true
import re, sys, time
from datetime import datetime, timedelta
m = re.findall(r"try again (?:at|after) ([A-Za-z0-9 ,:]+?(?:AM|PM))", sys.argv[1], re.I)
if m:
    text = re.sub(r"(\d+)(st|nd|rd|th)", r"\1", m[-1].strip())
    now = datetime.now()
    for fmt in ("%b %d, %Y %I:%M %p", "%B %d, %Y %I:%M %p", "%I:%M %p"):
        try:
            at = datetime.strptime(text, fmt)
        except ValueError:
            continue
        if fmt == "%I:%M %p":
            at = now.replace(hour=at.hour, minute=at.minute, second=0, microsecond=0)
            if at <= now:
                at += timedelta(days=1)
        delta = int((at - now).total_seconds()) + 60
        if 0 < delta <= 7 * 86400:
            print(delta)
        break
PY
)"
        [[ "${reset}" =~ ^[0-9]+$ ]] && seconds="${reset}"
    else
        return 0
    fi
    file="$(cli_cooldown_file "${tool}")"
    until=$(( $(date +%s) + seconds ))
    mkdir -p "$(dirname "${file}")" 2>/dev/null || return 0
    printf '%s\n%s\n' "${until}" "${reason}" > "${file}"
    echo "--> ${tool} parked for ${seconds}s (${reason}); remove ${file} to retry sooner"
}

run_cli_tool() {
    # run_cli_tool CONFIG TOOL WORKTREE PROMPT OUTPUT_FILE
    local config="${1}"
    local tool="${2}"
    local worktree="${3}"
    local prompt="${4}"
    local output_file="${5}"
    local rc remaining

    if remaining="$(cli_cooldown_remaining "${tool}")"; then
        # "cooldown" is a fallback-eligible marker for cli_error_allows_fallback.
        echo "cooldown: ${tool} parked for another ${remaining}s ($(sed -n 2p "$(cli_cooldown_file "${tool}")"))" | tee "${output_file}"
        return 75
    fi

    load_cli_command "${config}" "${tool}" "${worktree}" || return $?

    set +e
    if [[ "${CLI_PROMPT_MODE}" == "arg" ]]; then
        "${CLI_COMMAND[@]}" "${prompt}" < /dev/null 2>&1 | tee "${output_file}"
        rc=${PIPESTATUS[0]}
    else
        printf '%s\n' "${prompt}" | "${CLI_COMMAND[@]}" 2>&1 | tee "${output_file}"
        rc=${PIPESTATUS[1]}
    fi
    set -e
    if [[ "${rc}" -ne 0 ]]; then
        cli_record_cooldown "${tool}" "${output_file}" "${rc}"
    fi
    return "${rc}"
}

cli_error_allows_fallback() {
    # cli_error_allows_fallback OUTPUT_FILE
    # Only classify errors that indicate the CLI itself is unavailable. Avoid
    # broad words such as "auth", "permission", or "expired", which can also
    # describe a genuine failure in the task the agent was asked to perform.
    grep -Eqi \
        'limit|quota|credit balance|insufficient credits|429|too many requests|cooldown|overloaded|throttl|native binary not installed|postinstall did not run|optional dependency was not downloaded|authentication (failed|required|error)|failed to authenticate|oauth[^[:alnum:]]*(token[^[:alnum:]]*)?(failed|invalid|expired|required|error)|(^|[^[:digit:]])401([^[:digit:]]|$)|unauthorized|credentials?[^[:alnum:]]+(are )?(missing|invalid|expired|required|not (found|set))|(api[[:space:]_-]*key|access token)[^[:alnum:]]+(is )?(missing|invalid|expired|required|not (found|set))|not logged in|login required|please (log|sign) in|run .*(auth login|login to authenticate)' \
        "${1}"
}
