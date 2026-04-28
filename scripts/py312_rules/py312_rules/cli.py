"""CLI entrypoint: `refactor-py312 <paths...>`.

Wraps refactor.run() with the bundled rule set.
"""
from __future__ import annotations

from refactor import run

from .rules import AsyncioGetEventLoopRule, DistutilsRule, RemovedStdlibImportRule


def main() -> None:
    run(rules=[AsyncioGetEventLoopRule, RemovedStdlibImportRule, DistutilsRule])


if __name__ == "__main__":
    main()
