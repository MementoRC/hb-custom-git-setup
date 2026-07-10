import sys
from pathlib import Path

# Make scripts/ importable so `import select_tests` works.
SCRIPTS_DIR = Path(__file__).parent.parent
sys.path.insert(0, str(SCRIPTS_DIR))


def pytest_configure(config):
    config.addinivalue_line(
        "markers", "cli: integration tests that exercise the CLI entry point"
    )
