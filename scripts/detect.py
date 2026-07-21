#!/usr/bin/env python3
"""triage/detect.py — deterministic detection of pending work across watched repos.

Output: JSON report to stdout, state/last-tick.json, and state/history/.
No LLM calls.

Each item: {
  "kind": "engineer" | "review" | "dependabot" | "release",
  "mode": "issue" | "pr",
  "repo": "owner/name",
  "number": 123,
  "title": "...",
  "url": "...",
  "reason": "short reason"
}
"""
from __future__ import annotations
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib
    except ImportError:
        tomllib = None

def parse_simple_toml(file_path: str) -> dict:
    import re
    config: dict = {}
    current_section = None
    array_sections: dict = {}
    with open(file_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            array_match = re.match(r"^\[\[([^\]]+)\]\]$", line)
            if array_match:
                sect = array_match.group(1)
                new_table: dict = {}
                array_sections.setdefault(sect, []).append(new_table)
                config[sect] = array_sections[sect]
                current_section = new_table
                continue
            section_match = re.match(r"^\[([^\]]+)\]$", line)
            if section_match:
                sect = section_match.group(1)
                parts = sect.split(".")
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
                    items = []
                    for item in re.findall(r'"([^"]*)"', val):
                        items.append(item)
                    current_section[key] = items
                elif val.startswith('"') and val.endswith('"'):
                    current_section[key] = val[1:-1]
                elif val.lower() in ("true", "false"):
                    current_section[key] = val.lower() == "true"
                else:
                    try:
                        current_section[key] = int(val)
                    except ValueError:
                        current_section[key] = val
    return config

def load_config() -> dict:
    config_path = os.environ.get("TRIAGE_CONFIG", "/srv/agentic-dev/triage.toml")
    if not os.path.exists(config_path):
        return {}
    try:
        if tomllib:
            with open(config_path, "rb") as f:
                return tomllib.load(f)
        else:
            return parse_simple_toml(config_path)
    except Exception as e:
        print(f"[warn] failed to load config at {config_path}: {e}", file=sys.stderr)
        return {}

CONFIG = load_config()

WATCH_REPOS = [r["name"] for r in CONFIG.get("repos", []) if "name" in r]
if not WATCH_REPOS:
    WATCH_REPOS = []

AGENT_LOGIN = CONFIG.get("agent", {}).get("login", "agent-login")
HUMAN_LOGIN = CONFIG.get("agent", {}).get("human_login", "human-login")
APPROVED_LABEL = "approved"
CHANGES_REQUESTED_LABEL = "changes-requested"
BLOCKED_LABEL = "blocked"
TERMINAL_REVIEW_LABELS = {APPROVED_LABEL, CHANGES_REQUESTED_LABEL, BLOCKED_LABEL}
STATE_DIR = Path(os.environ.get("TRIAGE_STATE_DIR", "/srv/agentic-dev/state"))
HISTORY_RETENTION_DAYS = int(os.environ.get("TRIAGE_HISTORY_RETENTION_DAYS", "14"))

limits_config = CONFIG.get("limits", {})
OPEN_PR_CAP_PER_REPO = int(limits_config.get("open_pr_cap_per_repo", int(os.environ.get("TRIAGE_OPEN_PR_CAP_PER_REPO", "3"))))
LIVE_LOCK_SLUGS: set[str] = set()
DEPENDABOT_LOGIN = os.environ.get("TRIAGE_DEPENDABOT_LOGIN", "dependabot[bot]")
TODAY_UTC = time.strftime("%Y-%m-%d", time.gmtime())


def gh(args: list[str]) -> Any:
    """Run gh, parse JSON output. Return [] on failure."""
    try:
        r = subprocess.run(
            ["gh"] + args, capture_output=True, text=True, timeout=30, check=True
        )
        return json.loads(r.stdout) if r.stdout.strip() else []
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, json.JSONDecodeError) as e:
        print(f"[warn] gh failed for {args[:3]}: {e}", file=sys.stderr)
        return []


def lock_slug(kind: str, repo: str, number: int | str) -> str:
    return f"{kind}-{repo.replace('/', '_')}-{number}"


def mark_live_lock(kind: str, repo: str, number: int | str) -> None:
    LIVE_LOCK_SLUGS.add(lock_slug(kind, repo, number))


def skip(repo: str, number: int | str, reason: str) -> None:
    print(f"[skip] {repo}#{number}: {reason}", file=sys.stderr)


def check_names(checks: list[dict[str, Any]]) -> str:
    names = [c.get("name") or c.get("context") for c in checks]
    return ", ".join(str(n) for n in names if n) or "unnamed checks"


def bad_checks(checks: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        c
        for c in checks
        if c.get("conclusion") in ("FAILURE", "CANCELLED", "TIMED_OUT")
    ]


def pending_checks(checks: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        c
        for c in checks
        if c.get("status") in ("IN_PROGRESS", "QUEUED", "PENDING", "WAITING")
    ]


def non_successful_completed_checks(checks: list[dict[str, Any]]) -> list[dict[str, Any]]:
    acceptable = {"SUCCESS", "NEUTRAL", "SKIPPED"}
    return [
        c
        for c in checks
        if c.get("status") != "COMPLETED"
        or (c.get("conclusion") or "").upper() not in acceptable
    ]


def count_open_agent_prs(repo: str) -> int:
    """Open PRs authored by AGENT_LOGIN in repo — drives the per-repo cap."""
    prs = gh([
        "pr", "list", "-R", repo,
        "--author", AGENT_LOGIN,
        "--state", "open",
        "--limit", "50",
        "--json", "number",
    ])
    return len(prs) if isinstance(prs, list) else 0


def demote_stale_approved_prs(repo: str) -> None:
    """Find open PRs authored by AGENT_LOGIN that have the 'approved' label
    but are conflicting, dirty, behind main, or have bad/red CI checks,
    and demote them back to the agent loop.
    """
    prs = gh([
        "pr", "list", "-R", repo,
        "--state", "open",
        "--limit", "50",
        "--json", "number,labels,assignees,mergeStateStatus,mergeable,author,statusCheckRollup",
    ])
    if not isinstance(prs, list):
        return

    for pr in prs:
        author = (pr.get("author") or {}).get("login")
        if author != AGENT_LOGIN:
            continue
        
        labels = pr_label_names(pr)
        if APPROVED_LABEL not in labels:
            continue
            
        merge_state = (pr.get("mergeStateStatus") or "").upper()
        mergeable = (pr.get("mergeable") or "").upper()
        
        checks = pr.get("statusCheckRollup") or []
        has_bad_checks = len(bad_checks(checks)) > 0
        
        needs_demotion = (merge_state == "BEHIND" or mergeable in ("CONFLICTING", "DIRTY") or has_bad_checks)
        
        if needs_demotion:
            num = pr["number"]
            print(f"[demote] {repo}#{num}: approved PR is {merge_state}/{mergeable} (red CI: {has_bad_checks}), returning to engineering loop", file=sys.stderr)
            
            # 1. Remove approved label
            subprocess.run([
                "gh", "api", "-X", "DELETE",
                f"repos/{repo}/issues/{num}/labels/{APPROVED_LABEL}"
            ], capture_output=True)
            
            # 2. Add AGENT_LOGIN as assignee
            subprocess.run([
                "gh", "api", "-X", "POST",
                f"repos/{repo}/issues/{num}/assignees",
                "-f", f"assignees[]={AGENT_LOGIN}"
            ], capture_output=True)
            
            # 3. Remove HUMAN_LOGIN as assignee
            subprocess.run([
                "gh", "api", "-X", "DELETE",
                f"repos/{repo}/issues/{num}/assignees",
                "-f", f"assignees[]={HUMAN_LOGIN}"
            ], capture_output=True)


def detect_engineer_items(repo: str) -> list[dict]:
    """Open issues assigned to AGENT_LOGIN without a linked open PR.

    Gated by OPEN_PR_CAP_PER_REPO: if the agent already has that many open
    PRs in this repo, don't start more — let the existing ones drain through
    review/merge first. Fix iterations and rebases (detect_pr_engineer_items)
    are exempt because they unblock the queue rather than grow it.
    """
    open_prs = count_open_agent_prs(repo)
    cap_reached = open_prs >= OPEN_PR_CAP_PER_REPO
    issues = gh([
        "issue", "list", "-R", repo,
        "--assignee", AGENT_LOGIN,
        "--state", "open",
        "--limit", "50",
        "--json", "number,title,url,labels",
    ])
    out = []
    for it in issues:
        mark_live_lock("engineer", repo, it["number"])
        labels = {l["name"] for l in it.get("labels", [])}
        # skip if explicitly held
        if "do-not-work" in labels or "blocked" in labels:
            skip(repo, it["number"], "issue has do-not-work/blocked label")
            continue
        if cap_reached:
            skip(
                repo,
                it["number"],
                f"open-PR cap reached ({open_prs}/{OPEN_PR_CAP_PER_REPO}) — "
                "drain review/merge queue first",
            )
            continue
        # check for linked open PR
        prs = gh([
            "pr", "list", "-R", repo,
            "--state", "open",
            "--search", f"#{it['number']}",
            "--json", "number",
        ])
        if prs:
            skip(repo, it["number"], "issue already has linked open PR")
            continue
        out.append({
            "kind": "engineer",
            "mode": "issue",
            "repo": repo,
            "number": it["number"],
            "title": it["title"],
            "url": it["url"],
            "reason": "open issue assigned to agent, no open PR yet",
        })
    return out


def assigned_to(pr: dict[str, Any], login: str) -> bool:
    return any(a.get("login") == login for a in pr.get("assignees", []) if a)


def pr_label_names(pr: dict[str, Any]) -> set[str]:
    return {l.get("name") for l in pr.get("labels", []) if l.get("name")}


def repo_config(repo: str) -> dict[str, Any]:
    for item in CONFIG.get("repos", []):
        if item.get("name") == repo:
            return item
    return {}


def config_bool(section: str, key: str, default: bool) -> bool:
    value = CONFIG.get(section, {}).get(key, default)
    return value is True


def repo_bool(repo: str, key: str, default: bool) -> bool:
    value = repo_config(repo).get(key, default)
    return value is True


def default_branch(repo: str) -> str:
    data = gh(["repo", "view", repo, "--json", "defaultBranchRef"])
    if isinstance(data, dict):
        branch = ((data.get("defaultBranchRef") or {}).get("name") or "").strip()
        if branch:
            return branch
    return "main"


def repo_has_changes_since_latest_release(repo: str, branch: str) -> bool:
    latest = gh(["release", "list", "-R", repo, "--limit", "100", "--json", "tagName,isDraft"])
    latest_tag = ""
    if isinstance(latest, list):
        for item in latest:
            if item.get("isDraft"):
                continue
            tag = item.get("tagName") or ""
            if re.match(r"^v[0-9]+\.[0-9]+\.[0-9]+$", tag):
                latest_tag = tag
                break

    if not latest_tag:
        commits = gh([
            "api",
            "-X", "GET",
            f"repos/{repo}/commits",
            "-f", f"sha={branch}",
            "-f", "per_page=1",
        ])
        return isinstance(commits, list) and len(commits) > 0

    compare = gh([
        "api",
        "-X", "GET",
        f"repos/{repo}/compare/{latest_tag}...{branch}",
    ])
    if not isinstance(compare, dict):
        return False
    return int(compare.get("ahead_by") or 0) > 0


def detect_pr_engineer_items(repo: str) -> list[dict]:
    """Open assigned PRs needing an engineering fix iteration or a rebase."""
    pr_refs = gh([
        "pr", "list", "-R", repo,
        "--assignee", AGENT_LOGIN,
        "--state", "open",
        "--limit", "50",
        "--json", "number",
    ])
    out = []
    for pr_ref in pr_refs:
        pr = gh([
            "pr", "view", str(pr_ref["number"]), "-R", repo,
            "--json",
            "number,title,url,isDraft,statusCheckRollup,labels,assignees,mergeStateStatus,mergeable,headRepositoryOwner,isCrossRepository",
        ])
        if not isinstance(pr, dict):
            skip(repo, pr_ref.get("number", "?"), "gh pr view returned no PR object")
            continue
        mark_live_lock("engineer", repo, pr["number"])
        if pr.get("isDraft"):
            skip(repo, pr["number"], "draft PR")
            continue
        if assigned_to(pr, HUMAN_LOGIN):
            skip(repo, pr["number"], f"assigned to {HUMAN_LOGIN}")
            continue

        checks = pr.get("statusCheckRollup") or []
        bad = bad_checks(checks)
        pending = pending_checks(checks)
        labels = pr_label_names(pr)
        changes_requested = CHANGES_REQUESTED_LABEL in labels
        merge_state = (pr.get("mergeStateStatus") or "").upper()
        mergeable = (pr.get("mergeable") or "").upper()
        behind_main = merge_state in ("BEHIND", "DIRTY") or mergeable == "CONFLICTING"

        # Rebase has priority: if main moved on, fast-forward the branch first.
        # A rebase push restarts CI, so we don't also try to engineer/review on
        # the same tick — the next tick will see CI running and park the item.
        if behind_main and not pending:
            if pr.get("isCrossRepository"):
                skip(repo, pr["number"], "cross-repository (fork) PR cannot be auto-rebased")
                continue
            out.append({
                "kind": "engineer",
                "mode": "rebase",
                "repo": repo,
                "number": pr["number"],
                "title": pr["title"],
                "url": pr["url"],
                "reason": "PR behind base branch or conflicting, needs rebase",
            })
            continue

        # CI still running: don't dispatch anything yet — wait for it to settle.
        # Engineering is only "done" once CI is fully green.
        if pending and not bad and not changes_requested:
            if behind_main:
                skip(repo, pr["number"], f"behind base with pending CI ({check_names(pending)})")
            else:
                skip(repo, pr["number"], f"CI pending ({check_names(pending)})")
            continue

        if bad or changes_requested:
            reasons = []
            if bad:
                reasons.append("CI red")
            if changes_requested:
                reasons.append(f"{CHANGES_REQUESTED_LABEL} label")
            out.append({
                "kind": "engineer",
                "mode": "pr",
                "repo": repo,
                "number": pr["number"],
                "title": pr["title"],
                "url": pr["url"],
                "reason": "assigned PR needs fix iteration: " + " + ".join(reasons),
            })
            continue

        skip(repo, pr["number"], "no engineering signal")
    return out


def detect_review_items(repo: str) -> list[dict]:
    """Open non-draft PRs assigned to AGENT_LOGIN without a terminal workflow label."""
    prs = gh([
        "pr", "list", "-R", repo,
        "--assignee", AGENT_LOGIN,
        "--state", "open",
        "--limit", "50",
        "--json", "number,title,url,isDraft,statusCheckRollup,labels,assignees,mergeStateStatus,mergeable",
    ])
    out = []
    for pr in prs:
        mark_live_lock("review", repo, pr["number"])
        if pr.get("isDraft"):
            skip(repo, pr["number"], "draft PR")
            continue
        # AGENT_LOGIN assignment is guaranteed by the --assignee filter above;
        # only the human-takeover case needs an explicit skip.
        if assigned_to(pr, HUMAN_LOGIN):
            skip(repo, pr["number"], f"assigned to {HUMAN_LOGIN}")
            continue
        # Behind base or conflicting: rebase/fix detector will pick this up first; defer review.
        merge_state = (pr.get("mergeStateStatus") or "").upper()
        mergeable = (pr.get("mergeable") or "").upper()
        if merge_state in ("BEHIND", "DIRTY") or mergeable == "CONFLICTING":
            skip(repo, pr["number"], f"behind base or conflicting ({merge_state}/{mergeable}); review deferred")
            continue
        checks = pr.get("statusCheckRollup") or []
        # CI-green gate: engineering is only "done" once CI is fully green.
        # Skip if any check is red OR still running — wait for the next tick.
        bad = bad_checks(checks)
        if bad:
            skip(repo, pr["number"], f"CI red ({check_names(bad)})")
            continue
        pending = pending_checks(checks)
        if pending:
            skip(repo, pr["number"], f"CI pending ({check_names(pending)})")
            continue
        labels = pr_label_names(pr)
        terminal_labels = labels & TERMINAL_REVIEW_LABELS
        if terminal_labels:
            skip(repo, pr["number"], "terminal review label: " + ", ".join(sorted(terminal_labels)))
            continue
        out.append({
            "kind": "review",
            "mode": "pr",
            "repo": repo,
            "number": pr["number"],
            "title": pr["title"],
            "url": pr["url"],
            "reason": f"open PR assigned to {AGENT_LOGIN}, CI green, awaiting review",
        })
    return out


def detect_dependabot_items(repo: str) -> list[dict]:
    """Open Dependabot PRs that can be handled without a code-review LLM call."""
    if not config_bool("dependabot", "enabled", False):
        return []
    if not repo_bool(repo, "dependabot_automerge", False):
        return []

    prs = gh([
        "pr", "list", "-R", repo,
        "--author", DEPENDABOT_LOGIN,
        "--state", "open",
        "--limit", "50",
        "--json", "number,title,url,isDraft,statusCheckRollup,labels,mergeStateStatus,mergeable,isCrossRepository",
    ])
    if not isinstance(prs, list):
        return []

    out = []
    for pr in prs:
        mark_live_lock("dependabot", repo, pr["number"])
        if pr.get("isDraft"):
            skip(repo, pr["number"], "draft Dependabot PR")
            continue
        labels = pr_label_names(pr)
        if "do-not-merge" in labels or BLOCKED_LABEL in labels:
            skip(repo, pr["number"], "Dependabot PR has do-not-merge/blocked label")
            continue

        checks = pr.get("statusCheckRollup") or []
        if not checks:
            skip(repo, pr["number"], "Dependabot PR has no CI checks")
            continue
        bad = bad_checks(checks)
        pending = pending_checks(checks)
        if bad:
            skip(repo, pr["number"], f"Dependabot PR has red CI ({check_names(bad)})")
            continue
        if pending:
            skip(repo, pr["number"], f"Dependabot PR has pending CI ({check_names(pending)})")
            continue
        unknown = non_successful_completed_checks(checks)
        if unknown:
            skip(repo, pr["number"], f"Dependabot PR has non-successful checks ({check_names(unknown)})")
            continue

        merge_state = (pr.get("mergeStateStatus") or "").upper()
        mergeable = (pr.get("mergeable") or "").upper()
        mode = "merge"
        reason = "Dependabot PR is CI-green and ready for deterministic merge"
        if merge_state in ("BEHIND", "DIRTY") or mergeable == "CONFLICTING":
            if pr.get("isCrossRepository"):
                skip(repo, pr["number"], "cross-repository Dependabot PR cannot be auto-rebased")
                continue
            mode = "rebase"
            reason = "Dependabot PR is behind/conflicting and needs rebase before merge"

        out.append({
            "kind": "dependabot",
            "mode": mode,
            "repo": repo,
            "number": pr["number"],
            "title": pr["title"],
            "url": pr["url"],
            "reason": reason,
        })
    return out


def detect_release_items(repo: str) -> list[dict]:
    """Find repos due for a daily deterministic release."""
    if not config_bool("release", "enabled", False):
        return []
    if not repo_bool(repo, "release", False):
        return []

    mark_live_lock("release", repo, "daily")
    state_file = STATE_DIR / "release" / f"{repo.replace('/', '_')}.json"
    if state_file.exists():
        try:
            state = json.loads(state_file.read_text())
            if state.get("date") == TODAY_UTC:
                skip(repo, "release", f"daily release already evaluated on {TODAY_UTC}")
                return []
        except (OSError, json.JSONDecodeError):
            pass

    branch = default_branch(repo)
    if not repo_has_changes_since_latest_release(repo, branch):
        skip(repo, "release", "no commits since latest release")
        return []

    return [{
        "kind": "release",
        "mode": "daily",
        "repo": repo,
        "number": "daily",
        "title": f"Daily release for {repo}",
        "url": f"https://github.com/{repo}/releases",
        "reason": f"changes exist since latest release and no release ran on {TODAY_UTC}",
    }]


def prune_history(history_dir: Path) -> None:
    if HISTORY_RETENTION_DAYS <= 0:
        return
    cutoff = time.time() - (HISTORY_RETENTION_DAYS * 24 * 3600)
    for path in history_dir.glob("*.json"):
        try:
            if path.stat().st_mtime < cutoff:
                path.unlink()
        except OSError as e:
            print(f"[warn] could not prune history file {path}: {e}", file=sys.stderr)


def dedupe_items(items: list[dict]) -> list[dict]:
    """Keep first detector result for the same dispatch target."""
    seen = set()
    out = []
    for item in items:
        key = (item.get("kind"), item.get("repo"), item.get("number"), item.get("mode"))
        if key in seen:
            continue
        seen.add(key)
        out.append(item)
    return out


def main() -> int:
    items: list[dict] = []
    for repo in WATCH_REPOS:
        demote_stale_approved_prs(repo)
        items.extend(detect_dependabot_items(repo))
        items.extend(detect_engineer_items(repo))
        items.extend(detect_pr_engineer_items(repo))
        items.extend(detect_review_items(repo))
        items.extend(detect_release_items(repo))
    items = dedupe_items(items)

    generated_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    report = {
        "generatedAt": generated_at,
        "watchRepos": WATCH_REPOS,
        "itemCount": len(items),
        "items": items,
        "liveLockSlugs": sorted(LIVE_LOCK_SLUGS),
        "historyRetentionDays": HISTORY_RETENTION_DAYS,
    }

    STATE_DIR.mkdir(parents=True, exist_ok=True)
    last = STATE_DIR / "last-tick.json"
    last.write_text(json.dumps(report, indent=2))
    history = STATE_DIR / "history"
    history.mkdir(parents=True, exist_ok=True)
    history_name = generated_at.replace("-", "").replace(":", "").replace("Z", "Z")
    (history / f"{history_name}.json").write_text(json.dumps(report, indent=2))
    prune_history(history)

    json.dump(report, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
