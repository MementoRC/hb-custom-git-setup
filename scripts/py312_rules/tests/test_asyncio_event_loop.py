"""Fixture-pair tests for AsyncioGetEventLoopRule."""
from __future__ import annotations

from refactor import Session

from py312_rules.rules import AsyncioGetEventLoopRule


def test_rewrites_get_event_loop_call() -> None:
    src = "import asyncio\n\nasync def f():\n    loop = asyncio.get_event_loop()\n"
    expected = "import asyncio\n\nasync def f():\n    loop = asyncio.get_running_loop()\n"
    session = Session(rules=[AsyncioGetEventLoopRule])
    result = session.run(src)
    assert result == expected


def test_leaves_unrelated_calls_alone() -> None:
    src = "import asyncio\n\nasync def f():\n    return asyncio.sleep(1)\n"
    session = Session(rules=[AsyncioGetEventLoopRule])
    assert session.run(src) == src
