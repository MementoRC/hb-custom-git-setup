"""Flag Python 3.12-removed stdlib imports.

These modules were removed in Python 3.12: asynchat, asyncore, smtpd, sndhdr, telnetlib,
imghdr, mailcap, nntplib, ossaudiodev, spwd, xdrlib, audioop (3.13), aifc (3.13), cgi (3.13),
cgitb (3.13), chunk (3.13), crypt (3.13), pipes (3.13), nis (3.13), msilib (3.13).

This rule does NOT auto-rewrite — it raises a clear ImportError shim so the migration owner
can replace each call site manually with the recommended successor. We keep the import so
test discovery still parses the file but raise on actual use.
"""
from __future__ import annotations

import ast

from refactor import Rule, Replace

REMOVED_312 = {"asynchat", "asyncore", "smtpd", "sndhdr", "telnetlib", "imghdr",
               "mailcap", "nntplib", "ossaudiodev", "spwd", "xdrlib"}


class RemovedStdlibImportRule(Rule):
    """Replace `import <removed_module>` with a shim that raises on use."""

    def match(self, node: ast.AST) -> Replace:
        assert isinstance(node, ast.Import)
        assert len(node.names) == 1
        name = node.names[0].name
        assert name in REMOVED_312
        alias = node.names[0].asname or name

        # Generate: <alias> = _Py312RemovedModule("<name>")
        new_node = ast.Assign(
            targets=[ast.Name(id=alias, ctx=ast.Store())],
            value=ast.Call(
                func=ast.Name(id="_Py312RemovedModule", ctx=ast.Load()),
                args=[ast.Constant(value=name)],
                keywords=[],
            ),
        )
        # ast.unparse() requires location info on every node — copy from the
        # original import and fill in any missing positions on synthesized children.
        ast.copy_location(new_node, node)
        ast.fix_missing_locations(new_node)
        return Replace(node, new_node)
