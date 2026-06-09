# Agent Instructions

These rules apply to humans and automated agents working in `agentic-dev`.
The repository implements an engineering triage loop that can execute commands,
modify repositories, and act through GitHub, so operational safety is part of
correctness.

## Working Rules

1. Read this file and [README.md](README.md) before changing the repository.
2. Keep each change scoped to its issue. Avoid unrelated refactors.
3. Preserve the deterministic detector boundary: `scripts/detect.py` discovers
   work without invoking an LLM.
4. Treat shell arguments, issue text, configuration values, repository names,
   and worktree paths as untrusted input. Use arrays and quoted expansions;
   never construct commands with `eval`.
5. Do not print, commit, or place credentials in prompts. Logs and fixtures must
   use sanitized values.
6. Preserve human control points. Changes to assignment, approval, merge, or
   deployment behavior must document permissions, failure modes, and rollback.
7. Keep installed paths and repository paths distinct. Changes to scripts,
   systemd units, or `install.sh` must remain consistent with each other.
8. Add or update focused tests for behavioral changes. CI must be green before
   a pull request is considered complete.
9. Commit completed work, push the issue branch, and link the pull request to
   its issue.

## Versioning

This repository follows Semantic Versioning for releases:

- `PATCH` fixes behavior without changing supported configuration or interfaces.
- `MINOR` adds backward-compatible configuration or capabilities.
- `MAJOR` changes configuration, installation, command behavior, or operational
  contracts incompatibly.

Until the first tagged release, do not invent or update a version file. When a
release process is introduced, the version source, changelog, and git tag must
be updated together. Pull requests that change user-visible behavior must state
the expected release impact.

## Required Checks

Run the checks represented in `.github/workflows/validate.yml`:

```bash
./tests/test_cli_dispatch.sh
```

## Recommended Local Checks

For additional code quality and syntax validation, you are encouraged to run:

```bash
for file in install.sh scripts/*.sh tests/*.sh; do bash -n "$file"; done
shellcheck --severity=warning install.sh scripts/*.sh tests/*.sh
python3 -m py_compile scripts/*.py
python3 -c 'import pathlib, tomllib; tomllib.loads(pathlib.Path("triage.toml").read_text())'
```

