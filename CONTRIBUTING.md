# Contributing to agentic-dev

Contributions to the engineering triage loop are welcome through issues and
pull requests.

## Before Starting

1. Read [README.md](README.md) for the architecture and operating model.
2. Read [AGENTS.md](AGENTS.md) for repository safety and versioning rules.
3. Search existing issues and keep the change scoped to one objective.
4. For substantial behavioral changes, describe permissions, failure modes,
   compatibility, and rollback in the issue or pull request.

## Development Rules

- Work on a branch and link the pull request to its issue.
- Do not commit credentials, private repository content, production logs, or
  personal information.
- Quote shell expansions and use argument arrays for commands influenced by
  configuration or GitHub content.
- Keep detection deterministic and free of LLM calls.
- Add focused regression coverage for changed behavior.
- Update README examples and `triage.toml` when configuration changes.
- Follow the Semantic Versioning policy in [AGENTS.md](AGENTS.md).

## Local Validation

Run the same checks as CI:

```bash
npx --yes markdownlint-cli2 "*.md" ".github/**/*.md"
for file in install.sh scripts/*.sh tests/*.sh; do bash -n "$file"; done
shellcheck install.sh scripts/*.sh tests/*.sh
python3 -m py_compile scripts/*.py
python3 -c 'import pathlib, tomllib; tomllib.loads(pathlib.Path("triage.toml").read_text())'
./tests/test_cli_dispatch.sh
```

If a required tool is unavailable, report that explicitly in the pull request
instead of claiming the check passed.

## Pull Requests

A pull request should explain what changed, why it is needed, operational or
security impact, exact validation performed, and release-version impact.
Breaking behavior requires a migration and rollback plan.

By submitting a contribution, you agree that it is licensed under the
[Apache License 2.0](LICENSE).
