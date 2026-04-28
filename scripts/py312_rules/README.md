# py312-rules

Custom AST rules for Python 3.10 → 3.12 migration on the Hummingbot bleeding-edge fork.

Built on the [refactor](https://refactor.readthedocs.io) framework.

## Install (editable, from custom_git_setup)

```bash
pip install -e ./py312_rules
```

## Run

```bash
refactor-py312 hummingbot test controllers scripts
```

## Rules

| Rule | Pattern |
|------|---------|
| `AsyncioGetEventLoopRule` | `asyncio.get_event_loop()` → `asyncio.get_running_loop()` (in async contexts) |
| `RemovedStdlibImportRule` | Replace removed stdlib imports with raise-on-use shims |
| `DistutilsRule` | `from distutils.version import LooseVersion/StrictVersion` → `packaging.version.Version` |

## Adding rules

Each rule subclasses `refactor.Rule` and implements `match(node)` returning `Replace(node, new_node)`.
Add the class to `rules/__init__.py` `__all__` list and to `cli.py` `run(rules=[...])`.
Each rule needs at least one positive and one negative fixture-pair test in `tests/`.

## Idempotency

Rules MUST be idempotent: running them twice must produce zero diff. The rebuild pipeline
asserts this. Test it locally with:

```bash
refactor-py312 <files>
git diff --stat   # capture state
refactor-py312 <files>
git diff --stat   # must equal previous (no new changes)
```
