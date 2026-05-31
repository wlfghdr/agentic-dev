# Agentic Dev Triage Loop

Deterministic triage loop for agentic software engineering teams.

## Configuration

The loop is configured via `/srv/wulfai/triage/triage.toml`:

```toml
[agent]
login = "WulfAI"
human_login = "wlfghdr"

[limits]
max_engineer = 3
max_review = 2
open_pr_cap_per_repo = 3
lock_ttl_hours = 6

[cli_chain]
engineer = ["codex", "claude", "agy"]
review   = ["claude", "codex", "agy"]
rebase   = ["claude", "agy", "codex"]

[[repos]]
name = "WulfAI/sagi"
automerge = true

[[repos]]
name = "wlfghdr/agentic-enterprise"
automerge = false
```

## Installation

```bash
sudo ./install.sh
```
