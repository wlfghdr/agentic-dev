# Changelog

All notable changes to **agentic-dev** are documented here.

This file follows the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) convention.
The project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html): `MAJOR.MINOR.PATCH`.

## Versioning Conventions

| Bump | When to use |
|------|-------------|
| **PATCH** | Bug fixes, prose edits, clarifications that don't change behavior |
| **MINOR** | New scripts, new configuration options, non-breaking behavior additions |
| **MAJOR** | Breaking changes to `triage.toml`, script interfaces, or the systemd contract |

---

## [Unreleased]

### Fixed

- **Python 3.8 compatibility** in `scripts/cli_dispatch.sh` — replaced dict union operator `|` with `.copy()` + `.update()` to prevent TypeError crashes on older environments.
- **macOS compatibility** in `scripts/tick.sh` — added `get_lock_mtime` to portably handle `stat` differences between Linux and macOS, and added a graceful fallback when `flock` is not installed.
- **Path substitutions** in `install.sh` — updated default deployment directory to `/srv/wulfai/triage` and enabled compilation of path substitutions inside systemd drop-in configuration files.

## [0.1.0] — 2026-06-10

First versioned release of the deterministic engineering triage loop.

### Added

- **Deterministic triage scanner** (`scripts/detect.py`) — scans watched repos for assigned issues, PRs needing review, and PRs falling behind. No LLM calls during detection.
- **Orchestrator tick** (`scripts/tick.sh`) — lock acquisition, concurrency limits, and dispatch to transient `systemd-run` units for parallel execution.
- **Shared CLI-chain dispatch** (`scripts/cli_dispatch.sh`) — configurable multi-agent fallback chains (`codex`, `claude`, `kiro`, `agy`, plus custom `[cli_tools.NAME]` entries) with `stdin`/`arg` prompt modes (#5, #9, #10, #11).
- **Engineer / review / merge runners** (`scripts/engineer.sh`, `scripts/review.sh`, `scripts/merge.sh`) — worktree isolation, reviewer verdicts, and opt-in automerge.
- **Systemd units** (`systemd/`) — 60-second near-realtime timer, service, and dispatch drop-in override.
- **Log rotation** (`logrotate/agentic-triage`) and `install.sh` for VPS installation.
- **Regression tests** (`tests/test_cli_dispatch.sh`).
- **Release automation** — new `.github/workflows/release.yml`: pushing a `v*` tag creates the matching GitHub release with notes extracted from the changelog. Same workflow ships across agentic-enterprise, agentic-kb, and agentic-dev for a consistent suite release process.
- **LICENSE** (Apache-2.0), `VERSION`, and this changelog.
- **Website** (`index.html`) — GitHub Pages one-pager positioning agentic-dev as the execution layer of the agentic-* suite, with cross-references to [agentic-enterprise](https://github.com/wlfghdr/agentic-enterprise) and [agentic-kb](https://github.com/wlfghdr/agentic-kb).
