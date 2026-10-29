"""Headlines from the branch-tracking cron's plain-text summaries."""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

LOG_DIR = Path(__file__).resolve().parent.parent / "logs"
SUMMARIES = {
    "Cron sync": LOG_DIR / "cron" / "latest_summary.txt",
    "Manual rebuild": LOG_DIR / "manual_rebuild_latest.txt",
    "Interface check": LOG_DIR / "interface_check_latest.txt",
}
_HEADLINE_RE = re.compile(r"^(?:Overall|Status):\s*(.+)$", re.MULTILINE)
_WHEN_RE = re.compile(r"^(?:Completed|Date):\s*(.+)$", re.MULTILINE)


@dataclass
class Summary:
    name: str
    path: Path
    headline: str
    ran_at: str
    modified: datetime | None
    text: str

    @property
    def level(self) -> str:
        """success / warning / error / info, for colouring the headline."""
        head = self.headline.upper()
        if "DEGRADED" in head or "WARN" in head:
            return "warning"
        if any(word in head for word in ("FAIL", "BLOCKED", "CONFLICT", "INCOMPATIBLE", "ERROR")):
            return "error"
        if any(word in head for word in ("CLEAN", "COMPATIBLE", "PASS", "SUCCESS")):
            return "success"
        return "info"


def read_summary(name: str, path: Path) -> Summary:
    if not path.exists():
        return Summary(name, path, "missing", "", None, "")
    text = path.read_text(errors="replace")
    headline = _HEADLINE_RE.search(text)
    ran_at = _WHEN_RE.search(text)
    return Summary(
        name=name,
        path=path,
        headline=headline.group(1).strip() if headline else "unknown",
        ran_at=ran_at.group(1).strip() if ran_at else "",
        modified=datetime.fromtimestamp(path.stat().st_mtime).astimezone(),
        text=text,
    )


def summaries() -> list[Summary]:
    return [read_summary(name, path) for name, path in SUMMARIES.items()]


if __name__ == "__main__":
    for summary in summaries():
        print(f"{summary.name}: {summary.headline} ({summary.ran_at or 'no timestamp'})")
