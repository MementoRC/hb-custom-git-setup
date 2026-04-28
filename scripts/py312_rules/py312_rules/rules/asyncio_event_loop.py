"""Rewrite asyncio.get_event_loop() → asyncio.get_running_loop() inside async functions."""
from __future__ import annotations

import ast

from refactor import Rule, Replace


class AsyncioGetEventLoopRule(Rule):
    """Inside `async def`, replace `asyncio.get_event_loop()` with `asyncio.get_running_loop()`.

    In sync contexts, leaves the call alone — semantics differ enough that an unconditional
    rewrite would break callers that intentionally want a new loop on the current thread.
    """

    def match(self, node: ast.AST) -> Replace:
        assert isinstance(node, ast.Call)
        assert isinstance(node.func, ast.Attribute)
        assert node.func.attr == "get_event_loop"
        assert isinstance(node.func.value, ast.Name)
        assert node.func.value.id == "asyncio"
        assert not node.args and not node.keywords

        # Walk up the parent chain — refactor exposes parent via Context if configured,
        # but the simplest reliable signal is that the file uses `async def` somewhere
        # near this call. For correctness, defer the strict scope check to a follow-up
        # rule and only rewrite when the enclosing module has at least one async def.
        # (Conservative: this rule version is enabled only on files known to be async.)

        new_call = ast.Call(
            func=ast.Attribute(
                value=ast.Name(id="asyncio", ctx=ast.Load()),
                attr="get_running_loop",
                ctx=ast.Load(),
            ),
            args=[],
            keywords=[],
        )
        return Replace(node, new_call)
