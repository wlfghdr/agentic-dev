# Agentic Dev: The Engineering Triage Loop

`agentic-dev` is a production-grade, deterministic triage and execution loop designed for agentic software engineering teams. It serves as the **third core component** of the Agentic Enterprise suite, alongside:
1. **agentic-enterprise**: public organization frameworks, templates, and multi-agent reference models.
2. **agentic-kb**: layered knowledge base specification and operations (featuring the `/kb` command).
3. **agentic-dev**: the engineering execution layer that coordinates automated dispatching, code generation, conflict resolution, PR verification, and code review.

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
          │   tick.sh   │ (Spawns parallel transient systemd jobs)
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
 │ PR Created  │   │   Verdict   │ (merge-ready / needs-fix)
 └─────────────┘   └─────────────┘
```

---

## Repository Structure

- `scripts/`
  - `detect.py`: Deterministically scans watched repositories to identify issues assigned to the agent, PRs needing review, and PRs falling behind. *No LLM calls are made here.*
  - `tick.sh`: The orchestrator timer script. Acquires item locks, checks concurrency limits, and dispatches tasks to transient `systemd-run` units for safe, parallel execution.
  - `engineer.sh`: Sets up repository worktrees, runs the designated agent chain to write code/resolve conflicts, and pushes results or opens a PR.
  - `review.sh`: Pulls the code, spawns the reviewer agent chain, runs local verification tests, and posts the review comment with a final `VERDICT`.
  - `merge.sh`: Automatically merges approved PRs if `automerge` is enabled for the repository.
- `systemd/`
  - `triage-tick.service`: Systemd service to run the orchestrator tick.
  - `triage-tick.timer`: Near-realtime timer that triggers the service every 60 seconds.
- `logrotate/`
  - `agentic-triage`: Log rotation configuration to prevent disk space issues on the VPS.
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

## Installation

Run the installation script as root on your VPS or orchestrator host:

```bash
sudo ./install.sh
```

This will:
1. Copy all scripts to `/srv/agentic-dev/bin/`.
2. Initialize directories for state, locks, and history.
3. Install systemd service and timer files.
4. Enable the systemd timer.

To enable active dispatches in production, install the systemd drop-in override (set `TRIAGE_ENABLE_DISPATCH=1` and configure `HOME=/root` so the `gh` CLI can authenticate). See `systemd/triage-tick.service.d/dispatch.conf`.
