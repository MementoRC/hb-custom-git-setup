"""Rewrite common `from distutils.X import Y` patterns to their packaging/setuptools equivalents.

distutils was removed in Python 3.12. Most call sites map cleanly:
  distutils.version.LooseVersion / StrictVersion → packaging.version.Version
  distutils.util.strtobool                       → custom shim (no direct replacement)
  distutils.spawn.find_executable                → shutil.which
"""
from __future__ import annotations

import ast

from refactor import Rule, Replace

VERSION_NAMES = {"LooseVersion", "StrictVersion"}


class DistutilsRule(Rule):
    """Map `from distutils.version import LooseVersion` → `from packaging.version import Version`.

    Other distutils submodules (util, spawn, etc.) are left for manual review since their
    successors live in different stdlib/third-party modules with different signatures.
    """

    def match(self, node: ast.AST) -> Replace:
        assert isinstance(node, ast.ImportFrom)
        assert node.module == "distutils.version"
        assert all(n.name in VERSION_NAMES for n in node.names)

        new_names = [ast.alias(name="Version", asname=n.asname or n.name) for n in node.names]
        new_node = ast.ImportFrom(module="packaging.version", names=new_names, level=0)
        return Replace(node, new_node)
