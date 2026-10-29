"""gh CLI wrappers shared by the cockpit (read-only) and the needs-user helper."""

from __future__ import annotations

import json
import re
import subprocess
from dataclasses import dataclass
from datetime import datetime

OWNER = "MementoRC"
LABEL = "needs-user"
PROJECT_TITLE = "Hummingbot Cockpit"
STATUSES = ("Needs user", "In progress", "Blocked", "Done")
KINDS = ("decision", "verify", "review", "action")
SESSION_RE = re.compile(r"[\w.-]+")
MARKER_RE = re.compile(r"<!--\s*claude-session:([\w.-]+)\s*-->")


class GhError(RuntimeError):
    """A gh invocation failed; the message is gh's stderr."""


def marker(session: str) -> str:
    """Hidden tag on every post a session makes, so user replies can be told apart."""
    return f"<!-- claude-session:{session} -->"


def gh(*args: str) -> str:
    proc = subprocess.run(["gh", *args], capture_output=True, text=True, timeout=60, check=False)
    if proc.returncode != 0:
        raise GhError(proc.stderr.strip() or f"gh {args[0]} failed (exit {proc.returncode})")
    return proc.stdout


def gh_json(*args: str):
    out = gh(*args)
    return json.loads(out) if out.strip() else None


def graphql(query: str, **variables: str) -> dict:
    args = ["api", "graphql", "-f", f"query={query}"]
    for key, value in variables.items():
        args += ["-f", f"{key}={value}"]
    return gh_json(*args)["data"]


def parse_ts(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


NEEDS_USER_QUERY = """
query($q: String!) {
  search(query: $q, type: ISSUE, first: 100) {
    nodes {
      __typename
      ... on Issue {
        number title url createdAt body
        repository { name }
        timelineItems(last: 100, itemTypes: [LABELED_EVENT, ISSUE_COMMENT]) {
          nodes {
            __typename
            ... on LabeledEvent { createdAt label { name } }
            ... on IssueComment { createdAt body }
          }
        }
      }
      ... on PullRequest {
        number title url createdAt body
        repository { name }
        timelineItems(last: 100, itemTypes: [LABELED_EVENT, ISSUE_COMMENT, PULL_REQUEST_REVIEW]) {
          nodes {
            __typename
            ... on LabeledEvent { createdAt label { name } }
            ... on IssueComment { createdAt body }
            ... on PullRequestReview { createdAt body }
          }
        }
      }
    }
  }
}
"""

OPEN_PRS_QUERY = """
query($q: String!) {
  search(query: $q, type: ISSUE, first: 100) {
    nodes {
      ... on PullRequest {
        number title url isDraft updatedAt reviewDecision
        repository { nameWithOwner }
        commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
      }
    }
  }
}
"""


@dataclass
class NeedsUserItem:
    repo: str
    number: int
    title: str
    url: str
    is_pr: bool
    labelled_at: datetime
    session: str | None
    last_reply_at: datetime | None

    @property
    def replied(self) -> bool:
        return self.last_reply_at is not None


def _needs_user_item(node: dict) -> NeedsUserItem:
    events = node["timelineItems"]["nodes"]
    label_times = [
        parse_ts(e["createdAt"])
        for e in events
        if e["__typename"] == "LabeledEvent" and e["label"]["name"] == LABEL
    ]
    labelled_at = max(label_times) if label_times else parse_ts(node["createdAt"])
    posts = [(node.get("body") or "", parse_ts(node["createdAt"]))]
    posts += [(e.get("body") or "", parse_ts(e["createdAt"])) for e in events if e["__typename"] != "LabeledEvent"]
    session = None
    last_reply_at = None
    for body, posted_at in posts:
        sessions = MARKER_RE.findall(body)
        if sessions:
            session = sessions[-1]
        elif body.strip() and posted_at > labelled_at:
            last_reply_at = posted_at  # timeline is chronological, so this ends on the latest reply
    return NeedsUserItem(
        repo=node["repository"]["name"],
        number=node["number"],
        title=node["title"],
        url=node["url"],
        is_pr=node["__typename"] == "PullRequest",
        labelled_at=labelled_at,
        session=session,
        last_reply_at=last_reply_at,
    )


def needs_user_items() -> list[NeedsUserItem]:
    """Open issues and PRs labelled needs-user in any repo owned by OWNER."""
    data = graphql(NEEDS_USER_QUERY, q=f"user:{OWNER} label:{LABEL} is:open")
    return [_needs_user_item(n) for n in data["search"]["nodes"] if n]


def open_prs() -> list[dict]:
    """Open PRs authored by OWNER anywhere, with the head commit's check rollup."""
    data = graphql(OPEN_PRS_QUERY, q=f"author:{OWNER} is:pr is:open sort:updated-desc")
    prs = []
    for node in data["search"]["nodes"]:
        if not node:
            continue
        commits = node["commits"]["nodes"]
        rollup = commits[0]["commit"]["statusCheckRollup"] if commits else None
        prs.append(
            {
                "repo": node["repository"]["nameWithOwner"],
                "number": node["number"],
                "title": node["title"],
                "url": node["url"],
                "draft": node["isDraft"],
                "review": node["reviewDecision"],
                "ci": rollup["state"] if rollup else None,
                "updated_at": parse_ts(node["updatedAt"]),
            }
        )
    return prs


def find_project() -> dict | None:
    data = gh_json("project", "list", "--owner", OWNER, "--format", "json", "--limit", "100")
    return next((p for p in data["projects"] if p["title"] == PROJECT_TITLE), None)


def project_items(number: int) -> list[dict]:
    data = gh_json("project", "item-list", str(number), "--owner", OWNER, "--format", "json", "--limit", "500")
    return data["items"]


def project_fields(number: int) -> dict[str, dict]:
    data = gh_json("project", "field-list", str(number), "--owner", OWNER, "--format", "json")
    return {f["name"]: f for f in data["fields"]}
