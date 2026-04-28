"""Fixture-pair tests for RemovedStdlibImportRule."""
from __future__ import annotations

from refactor import Session

from py312_rules.rules import RemovedStdlibImportRule


def test_replaces_removed_import_with_shim() -> None:
    src = "import asynchat\n"
    session = Session(rules=[RemovedStdlibImportRule])
    out = session.run(src)
    assert "_Py312RemovedModule" in out
    assert "'asynchat'" in out or '"asynchat"' in out


def test_leaves_present_imports_alone() -> None:
    src = "import asyncio\nimport os\n"
    session = Session(rules=[RemovedStdlibImportRule])
    assert session.run(src) == src
