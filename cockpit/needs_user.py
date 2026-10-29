"""needs-user: raise, list and resolve questions for the user.

Design: hummingbot_ai_docs/2026-10-29-tracking-cockpit-design.md

  pixi run needs-user open <repo> "<title>" <session> <kind> <body-file>
  pixi run needs-user flag <repo> <number> <session> <kind> [--comment-file F]
  pixi run needs-user list
  pixi run needs-user answered [session]
  pixi run needs-user resolve <repo> <number> [--close]
  pixi run needs-user setup-project

From another directory add --manifest-path /home/memento/PycharmProjects/Hummingbot/custom_git_setup/pixi.toml
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import ghdata
from ghdata import LABEL, OWNER, gh, gh_json, graphql, marker

STATUS_COLORS = {"Needs user": "RED", "In progress": "YELLOW", "Blocked": "ORANGE", "Done": "GREEN"}
UPDATE_STATUS_OPTIONS = """
mutation($field: ID!) {
  updateProjectV2Field(input: {fieldId: $field, singleSelectOptions: [OPTIONS]}) {
    projectV2Field { ... on ProjectV2SingleSelectField { name } }
  }
}
"""


def _repo(value: str) -> str:
    return value.removeprefix(f"{OWNER}/")


def _session(value: str) -> str:
    if not ghdata.SESSION_RE.fullmatch(value):
        raise argparse.ArgumentTypeError("session names are letters, digits, '.', '-' and '_'")
    return value


def _set_fields(url: str, status: str, session: str | None = None, kind: str | None = None) -> None:
    """Add url to the Project (idempotent) and set its fields; warn instead of failing, the label is the truth."""
    try:
        project = ghdata.find_project()
        if project is None:
            print(f'warning: no Project "{ghdata.PROJECT_TITLE}"; labelled only (run setup-project)', file=sys.stderr)
            return
        number = str(project["number"])
        item_id = gh("project", "item-add", number, "--owner", OWNER, "--url", url, "--format", "json", "--jq", ".id").strip()
        fields = ghdata.project_fields(project["number"])
        edit = ["project", "item-edit", "--id", item_id, "--project-id", project["id"]]
        for name, value in (("Status", status), ("Kind", kind)):
            if value:
                option = next(o["id"] for o in fields[name]["options"] if o["name"] == value)
                gh(*edit, "--field-id", fields[name]["id"], "--single-select-option-id", option)
        if session:
            gh(*edit, "--field-id", fields["Session"]["id"], "--text", session)
    except (ghdata.GhError, KeyError, StopIteration) as exc:
        print(f"warning: Project update skipped: {exc!r}", file=sys.stderr)


def cmd_open(args: argparse.Namespace) -> None:
    body = Path(args.body_file).read_text().rstrip() + f"\n\n{marker(args.session)}\n"
    out = gh("issue", "create", "-R", f"{OWNER}/{args.repo}", "--title", args.title, "--body", body, "--label", LABEL)
    url = out.strip().splitlines()[-1]
    _set_fields(url, "Needs user", args.session, args.kind)
    print(url)


def cmd_flag(args: argparse.Namespace) -> None:
    path = f"repos/{OWNER}/{args.repo}/issues/{args.number}"
    if args.comment_file:
        text = Path(args.comment_file).read_text().rstrip()
    else:
        text = f"Waiting on the user (raised by session `{args.session}`)."
    gh("api", f"{path}/comments", "-f", f"body={text}\n\n{marker(args.session)}")
    gh("api", f"{path}/labels", "-f", f"labels[]={LABEL}")
    url = gh("api", path, "--jq", ".html_url").strip()
    _set_fields(url, "Needs user", args.session, args.kind)
    print(url)


def _print_items(items: list[ghdata.NeedsUserItem]) -> None:
    for item in items:
        state = f"replied {item.last_reply_at:%Y-%m-%d %H:%M}Z" if item.last_reply_at else "waiting"
        print(f"{item.repo}#{item.number}\t{item.session or '-'}\t{state}\t{item.url}\t{item.title}")


def cmd_list(args: argparse.Namespace) -> None:
    _print_items(ghdata.needs_user_items())


def cmd_answered(args: argparse.Namespace) -> None:
    items = [i for i in ghdata.needs_user_items() if i.replied and args.session in (None, i.session)]
    _print_items(items)
    if not items:
        print("no answered needs-user items", file=sys.stderr)


def cmd_resolve(args: argparse.Namespace) -> None:
    path = f"repos/{OWNER}/{args.repo}/issues/{args.number}"
    issue = gh_json("api", path)
    if args.close and "pull_request" in issue:
        sys.exit("refusing --close on a pull request; merge or close it on GitHub")
    try:
        gh("api", "-X", "DELETE", f"{path}/labels/{LABEL}")
    except ghdata.GhError as exc:
        if "Not Found" not in str(exc) and "404" not in str(exc):
            raise
    if args.close:
        gh("issue", "close", str(args.number), "-R", f"{OWNER}/{args.repo}")
    _set_fields(issue["html_url"], "Done" if args.close else "In progress")
    print(issue["html_url"])


def cmd_setup_project(args: argparse.Namespace) -> None:
    project = ghdata.find_project()
    if project is None:
        project = gh_json("project", "create", "--owner", OWNER, "--title", ghdata.PROJECT_TITLE, "--format", "json")
        print(f"created {project['url']}")
    number = str(project["number"])
    gh(
        "project", "edit", number, "--owner", OWNER, "--visibility", "PRIVATE",
        "--description", "Cross-repo tracking; needs-user items raised by Claude sessions",
    )
    fields = ghdata.project_fields(project["number"])
    if [o["name"] for o in fields["Status"]["options"]] != list(ghdata.STATUSES):
        options = ", ".join(
            f'{{name: "{name}", color: {STATUS_COLORS[name]}, description: ""}}' for name in ghdata.STATUSES
        )
        graphql(UPDATE_STATUS_OPTIONS.replace("OPTIONS", options), field=fields["Status"]["id"])
    if "Session" not in fields:
        gh("project", "field-create", number, "--owner", OWNER, "--name", "Session", "--data-type", "TEXT")
    if "Kind" not in fields:
        gh(
            "project", "field-create", number, "--owner", OWNER, "--name", "Kind",
            "--data-type", "SINGLE_SELECT", "--single-select-options", ",".join(ghdata.KINDS),
        )
    print(project["url"])


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="needs-user", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("open", help="open an issue labelled needs-user and add it to the Project")
    p.add_argument("repo", type=_repo)
    p.add_argument("title")
    p.add_argument("session", type=_session)
    p.add_argument("kind", choices=ghdata.KINDS)
    p.add_argument("body_file")
    p.set_defaults(func=cmd_open)

    p = sub.add_parser("flag", help="ask on an existing issue or PR and label it needs-user")
    p.add_argument("repo", type=_repo)
    p.add_argument("number", type=int)
    p.add_argument("session", type=_session)
    p.add_argument("kind", choices=ghdata.KINDS)
    p.add_argument("--comment-file")
    p.set_defaults(func=cmd_flag)

    p = sub.add_parser("list", help="every open needs-user item")
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("answered", help="open needs-user items the user has replied to")
    p.add_argument("session", nargs="?", type=_session)
    p.set_defaults(func=cmd_answered)

    p = sub.add_parser("resolve", help="drop the label; --close also closes the issue")
    p.add_argument("repo", type=_repo)
    p.add_argument("number", type=int)
    p.add_argument("--close", action="store_true")
    p.set_defaults(func=cmd_resolve)

    p = sub.add_parser("setup-project", help="create or repair the Project and its fields (idempotent)")
    p.set_defaults(func=cmd_setup_project)

    args = parser.parse_args()
    try:
        args.func(args)
    except ghdata.GhError as exc:
        sys.exit(f"gh failed: {exc}")


if __name__ == "__main__":
    main()
