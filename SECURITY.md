# Security Policy

## Scope

`agentic-dev` coordinates GitHub operations, repository worktrees, agent CLIs,
and systemd jobs. Security-sensitive areas include command construction,
credential handling, untrusted issue or pull-request content, filesystem
isolation, assignment and approval transitions, and automated merges.

## Reporting a Vulnerability

Report suspected vulnerabilities privately through
[GitHub Security Advisories](https://github.com/wlfghdr/agentic-dev/security/advisories/new).
Do not open a public issue or include secrets, exploit details, private
repository data, or personal information in public discussions.

The maintainers aim to acknowledge reports within five business days. Any
broader organizational disclosure requirements also apply.

## Supported Versions

Until tagged releases exist, only the current `main` branch is supported.
After releases begin, the latest release line and `main` will receive security
updates unless a release notice states otherwise.

## Operational Guidance

- Use a dedicated GitHub identity with the minimum repository permissions.
- Store tokens outside the repository and do not pass secrets in agent prompts.
- Review `triage.toml` and systemd overrides before enabling dispatch or merge.
- Keep the human approval boundary enabled for repositories that require it.
- Treat issue bodies, comments, branch names, repository names, and agent output
  as untrusted input.
- Rotate credentials and inspect audit logs after suspected compromise.
