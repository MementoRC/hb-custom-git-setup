"""Fixture-pair tests for DistutilsRule."""
from __future__ import annotations

from refactor import Session

from py312_rules.rules import DistutilsRule


def test_rewrites_loose_version_import() -> None:
    src = "from distutils.version import LooseVersion\n"
    expected_substr = "from packaging.version import"
    session = Session(rules=[DistutilsRule])
    out = session.run(src)
    assert expected_substr in out
    assert "Version as LooseVersion" in out


def test_leaves_other_distutils_imports() -> None:
    src = "from distutils.spawn import find_executable\n"
    session = Session(rules=[DistutilsRule])
    assert session.run(src) == src
