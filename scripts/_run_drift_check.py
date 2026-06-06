#!/usr/bin/env python3
"""Helper to run drift-check.sh and verify output."""
import subprocess
import sys
import os
from pathlib import Path

script_dir = Path(__file__).parent
repo_path = "/home/memento/PycharmProjects/Hummingbot/hummingbot"
drift_check = script_dir / "drift-check.sh"

try:
    result = subprocess.run(
        [str(drift_check)],
        cwd=repo_path,
        capture_output=True,
        text=True,
        timeout=300
    )
    print("STDOUT:", result.stdout)
    if result.stderr:
        print("STDERR:", result.stderr)
    sys.exit(result.returncode)
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
