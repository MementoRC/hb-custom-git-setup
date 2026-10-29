"""Hummingbot cockpit: what needs the user, the Project board, open PRs and pipeline health.

Read-only. It runs gh with the user's token and reads the cron logs; answers happen on GitHub.
"""

from __future__ import annotations

from dataclasses import asdict
from datetime import datetime, timezone

import ghdata
import logdata
import streamlit as st

st.set_page_config(page_title="Hummingbot Cockpit", page_icon="🛰️", layout="wide")

CI_ICONS = {"SUCCESS": "✅", "FAILURE": "❌", "ERROR": "❌", "PENDING": "⏳", "EXPECTED": "⏳"}
LINK = st.column_config.LinkColumn("Link", display_text="open")


def ago(when: datetime | None) -> str:
    if when is None:
        return ""
    seconds = int((datetime.now(timezone.utc) - when).total_seconds())
    for unit, size in (("d", 86400), ("h", 3600), ("m", 60)):
        if seconds >= size:
            return f"{seconds // size}{unit}"
    return "now"


def _safe(fn, *args):
    try:
        return fn(*args), None
    except (ghdata.GhError, OSError, KeyError, TypeError, ValueError) as exc:
        return None, str(exc)


@st.cache_data(ttl=120, show_spinner="Asking GitHub...")
def load_needs_user():
    items, err = _safe(ghdata.needs_user_items)
    if items is None:
        return None, err
    return [asdict(i) | {"replied": i.replied} for i in items], None


@st.cache_data(ttl=120, show_spinner="Asking GitHub...")
def load_open_prs():
    return _safe(ghdata.open_prs)


@st.cache_data(ttl=120, show_spinner="Reading the Project...")
def load_project():
    project, err = _safe(ghdata.find_project)
    if err or project is None:
        return None, None, err or f'No Project titled "{ghdata.PROJECT_TITLE}" yet.'
    items, err = _safe(ghdata.project_items, project["number"])
    return project, items, err


def project_table(items: list[dict]) -> None:
    rows = []
    for item in items:
        content = item.get("content") or {}
        rows.append(
            {
                "Repo": (content.get("repository") or "").split("/")[-1],
                "#": content.get("number"),
                "Title": item.get("title") or content.get("title", ""),
                "Session": item.get("session", ""),
                "Kind": item.get("kind", ""),
                "Link": content.get("url", ""),
            }
        )
    st.dataframe(rows, column_config={"Link": LINK}, hide_index=True)


needs_user, needs_user_err = load_needs_user()
prs, prs_err = load_open_prs()
project, items, project_err = load_project()
pipeline = logdata.summaries()  # local files: cheap, never cached

head, refresh = st.columns([5, 1])
head.title("Hummingbot Cockpit")
head.caption("Read-only. Answer questions on GitHub; sessions pick replies up from there.")
if refresh.button("Refresh"):
    st.cache_data.clear()
    st.rerun()

waiting = [i for i in needs_user or [] if not i["replied"]]
replied = [i for i in needs_user or [] if i["replied"]]
failing = [p for p in prs or [] if p["ci"] in ("FAILURE", "ERROR")]
m1, m2, m3, m4 = st.columns(4)
m1.metric("Waiting on you", len(waiting))
m2.metric("Replied, not picked up", len(replied))
m3.metric("Open PRs", len(prs or []))
m4.metric("Failing CI", len(failing))

tab_needs, tab_project, tab_prs, tab_pipeline = st.tabs(["Needs you", "Project", "Open PRs", "Pipeline"])

with tab_needs:
    if needs_user_err:
        st.error(f"Could not search for `{ghdata.LABEL}` items: {needs_user_err}")
    elif not needs_user:
        st.success("Nothing is waiting on you.")
    else:
        rows = sorted(needs_user, key=lambda i: (i["replied"], i["labelled_at"]))
        st.dataframe(
            [
                {
                    "Repo": i["repo"],
                    "#": i["number"],
                    "Title": i["title"],
                    "Type": "PR" if i["is_pr"] else "issue",
                    "Session": i["session"] or "",
                    "Waiting": ago(i["labelled_at"]),
                    "Replied": f"yes, {ago(i['last_reply_at'])} ago" if i["replied"] else "",
                    "Link": i["url"],
                }
                for i in rows
            ],
            column_config={"Link": LINK},
            hide_index=True,
        )

with tab_project:
    if project_err:
        st.warning(project_err)
        st.caption("A scope error means the token needs `gh auth refresh -h github.com -s project` (once).")
    else:
        st.markdown(f"[{project['title']}]({project['url']}) · {len(items)} items")
        by_status: dict[str, list[dict]] = {}
        for item in items:
            by_status.setdefault(item.get("status") or "No status", []).append(item)
        for status in [*ghdata.STATUSES, *sorted(set(by_status) - set(ghdata.STATUSES))]:
            group = by_status.get(status)
            if not group:
                continue
            if status == "Done":
                with st.expander(f"Done ({len(group)})"):
                    project_table(group)
            else:
                st.subheader(f"{status} ({len(group)})")
                project_table(group)

with tab_prs:
    if prs_err:
        st.error(f"Could not list open PRs: {prs_err}")
    elif not prs:
        st.info("No open PRs.")
    else:
        st.dataframe(
            [
                {
                    "Repo": p["repo"].removeprefix(f"{ghdata.OWNER}/"),
                    "#": p["number"],
                    "Title": p["title"],
                    "CI": CI_ICONS.get(p["ci"], "—"),
                    "Review": (p["review"] or "").replace("_", " ").lower(),
                    "Draft": "draft" if p["draft"] else "",
                    "Updated": ago(p["updated_at"]),
                    "Link": p["url"],
                }
                for p in prs
            ],
            column_config={"Link": LINK},
            hide_index=True,
        )

with tab_pipeline:
    for summary in pipeline:
        line = f"**{summary.name}**: {summary.headline}"
        if summary.ran_at:
            line += f" · ran {summary.ran_at}"
        if summary.modified:
            line += f" · file {ago(summary.modified)} old"
        getattr(st, summary.level)(line)
        if summary.text:
            with st.expander("Full summary"):
                st.code(summary.text, language=None)
