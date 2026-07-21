# agentic-dev

> **Deterministic engineering triage loop.**
> Production-grade dispatching, code generation, conflict resolution, PR verification, and code review for agentic software engineering teams. No LLM calls during detection. Matches agent throughput to human approval bandwidth.

[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-v0.2.0-green.svg)](CHANGELOG.md)

**Website:** [wlfghdr.github.io/agentic-dev](https://wlfghdr.github.io/agentic-dev/)

## The agentic-* suite

`agentic-dev` is the **execution layer** of the agentic-* suite — three building blocks for running an agentic organization on Git:

| Repo | Role |
|------|------|
| [agentic-enterprise](https://github.com/wlfghdr/agentic-enterprise) | **The operating model** — governance layers, process loops, policies, and templates. Humans decide, agents execute, Git governs. |
| [agentic-kb](https://github.com/wlfghdr/agentic-kb) | **The knowledge layer** — layered, vendor-neutral knowledge ops via the `/kb` command. |
| [agentic-dev](https://github.com/wlfghdr/agentic-dev) | **The execution layer** — deterministic engineering triage and execution loop (this repo). |

---

## The Concept: Human-in-the-Loop Git Ops

In a mature agentic organization:
- **Git is the operating system** of the company.
- **Signals** (customer issues, observability alerts) are turned into **Missions** (GitHub Issues).
- **Missions** are picked up by autonomous **Engineers** (AI agents).
- **Engineer agents** propose changes via **Pull Requests**.
- **Reviewer agents** audit the PRs and verify tests, passing them to **Humans** for approval and release.

`agentic-dev` is the engine that drives this cycle, ensuring the workspace remains clean, tasks do not conflict, and agents only work on what is ready.

```
          ┌─────────────┐
          │  GH Issue   │ (Mission assigned to agent)
          └──────┬──────┘
                 │
                 ▼
          ┌─────────────┐
          │  detect.py  │ (Deterministic, no-LLM scanner)
          └──────┬──────┘
                 │
                 ▼
          ┌─────────────┐
          │   tick.sh   │ (Dispatches parallel transient systemd jobs)
          └──────┬──────┘
                 │
        ┌────────┴────────┐
        ▼                 ▼
 ┌─────────────┐   ┌─────────────┐
 │ engineer.sh │   │  review.sh  │
 └──────┬──────┘   └──────┬──────┘
        │                 │
        ▼                 ▼
 ┌─────────────┐   ┌─────────────┐
 │ Codex/Kiro/ │   │ Claude/Kiro/│ (LLM execution chains)
 │ Claude/AGY  │   │ Codex/AGY   │
 └──────┬──────┘   └──────┬──────┘
        │                 │
        ▼                 ▼
 ┌─────────────┐   ┌─────────────┐
 │ PR Created  │   │   Verdict   │ (merge-ready / needs-fix / blocked)
 └─────────────┘   └─────────────┘
```

---

## Repository Structure

- `scripts/`
  - `detect.py`: Deterministically scans watched repositories to identify issues assigned to the agent, PRs needing review, and PRs falling behind. *No LLM calls are made here.*
  - `tick.sh`: The orchestrator timer script. Acquires item locks, checks concurrency limits, and dispatches tasks to transient `systemd-run` units for safe, parallel execution.
  - `cli_dispatch.sh`: Shared CLI-chain configuration and execution helpers — resolves the configured agent CLI chain and runs prompts against it.
  - `engineer.sh`: Sets up repository worktrees, runs the designated agent chain to write code/resolve conflicts, and pushes results or opens a PR.
  - `review.sh`: Pulls the code, dispatches the reviewer agent chain, runs local verification tests, and posts the review comment with a final `VERDICT`.
  - `merge.sh`: Automatically merges approved PRs if `automerge` is enabled for the repository.
- `systemd/`
  - `triage-tick.service`: Systemd service to run the orchestrator tick.
  - `triage-tick.timer`: Near-realtime timer that triggers the service every 60 seconds.
- `logrotate/`
  - `agentic-triage`: Log rotation configuration to prevent disk space issues on the VPS.
- `tests/`
  - `test_cli_dispatch.sh`: Regression tests for the CLI-chain dispatch helpers.
- `triage.toml`: Main configuration file defining the triage agent name, human fallback, limits, execution chains, and watched repositories.

---

## Configuration

The loop is configured via `triage.toml` (default path: `/srv/agentic-dev/triage.toml`):

```toml
[agent]
login = "agent-login"
human_login = "human-login"

[limits]
max_engineer = 3            # Max parallel engineering dispatches
max_review = 2              # Max parallel review dispatches
open_pr_cap_per_repo = 3    # Cap open PRs per repo to match human approval bandwidth
lock_ttl_hours = 2          # TTL for stale locks

[cli_chain]
engineer = ["codex", "claude", "kiro", "agy"]  # Writing code
review   = ["claude", "codex", "kiro", "agy"]  # Code reviews
rebase   = ["claude", "kiro", "agy", "codex"]  # Conflict resolution

[cli_tools.kiro]
command = "kiro-cli"
args = ["chat", "--no-interactive", "--trust-all-tools"]
prompt_mode = "arg"

[[repos]]
name = "organization/repository-name"
automerge = true
```

Built-in command definitions are provided for `codex`, `claude`, `agy`, and
`kiro`. Any tool named in a chain can be configured under `[cli_tools.NAME]`:

- `command`: executable name or path.
- `args`: argument array. Each `{worktree}` token is replaced with the checkout
  path without shell evaluation.
- `prompt_mode`: `stdin` to pipe the prompt, or `arg` to append it as the final
  argument.

For example, a custom agent CLI can be added without changing the scripts:

```toml
[cli_tools.my-agent]
command = "/opt/agents/my-agent"
args = ["run", "--workspace", "{worktree}", "--auto-approve"]
prompt_mode = "stdin"
```

---

## Workflow labels

The loop coordinates through a small set of GitHub labels. Two are **human control points** you can apply by hand; the rest are **agent-managed** workflow state. Labels are the source of truth for what the loop will and will not pick up.

| Label | Set by | Meaning / effect |
|-------|--------|------------------|
| `do-not-work` | human | `detect.py` skips the issue entirely — use it to pause the agent on a specific item. |
| `blocked` | human or `review.sh` | Halts work: blocked issues are skipped, and a `VERDICT: blocked` review marks the PR for human attention. |
| `in-progress` | agent | An engineer dispatch is actively working the issue or PR. |
| `needs-review` | agent | PR is awaiting a review dispatch. |
| `changes-requested` | `review.sh` | Review verdict `needs-fix` — the engineer chain will revise on the next tick. |
| `approved` | `review.sh` | Review verdict `merge-ready` — PR is handed to the human (and auto-merged if `automerge` is enabled for the repo). |

The three review verdicts emitted by `review.sh` map onto labels as: `merge-ready` → `approved`, `needs-fix` → `changes-requested`, `blocked` → `blocked`.

---

## Installation

**Prerequisites:** Linux with systemd, Python ≥ 3.11 (`tomllib`), `git`, and an authenticated `gh` CLI, plus the agent CLIs you configure in your chains.

Run the installation script as root on your VPS or orchestrator host:

```bash
sudo ./install.sh
```

Production dispatch defaults to repositories under `/srv/wulfai/repos` and
worktrees under `/srv/wulfai/worktrees`. Set `TRIAGE_REPOS_DIR` and
`TRIAGE_WORKTREES_DIR` when running the installer to use different roots.

This will:
1. Copy all scripts to `/srv/agentic-dev/bin/`.
2. Initialize directories for state, locks, and history.
3. Install systemd service and timer files.
4. Enable the systemd timer.

To enable active dispatches in production, install the systemd drop-in override (set `TRIAGE_ENABLE_DISPATCH=1` and configure `HOME=/root` so the `gh` CLI can authenticate). See `systemd/triage-tick.service.d/dispatch.conf`.

---

## Contributing

Issues and PRs welcome. Keep changes focused: this repo is a deterministic loop, not a framework — speculative features belong in [agentic-enterprise](https://github.com/wlfghdr/agentic-enterprise) discussions first.

## License

Apache License 2.0 — see [LICENSE](LICENSE).

## Changelog

Release history lives in [`CHANGELOG.md`](CHANGELOG.md).
