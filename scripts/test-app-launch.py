#!/usr/bin/env python3
"""Exercise normal SwiftUI startup, notification settings, and a real app window."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile


def check_launch(app: Path) -> None:
    executable = app.resolve() / "Contents/MacOS/CitrusBattery"
    environment = dict(os.environ, CITRUS_GUI_SMOKE_TEST="1")
    with tempfile.TemporaryFile(mode="w+") as log:
        process = subprocess.Popen([str(executable)], env=environment, stdout=log, stderr=log)
        try:
            result = process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
            raise RuntimeError("GUI launch check timed out") from None
        finally:
            log.seek(0)
            output = log.read()
        if result != 0:
            raise RuntimeError(f"App exited during GUI launch (status {result}):\n{output}")
        for checkpoint in [
            "Citrus notification settings check passed",
            "Citrus GUI launch check passed",
        ]:
            if checkpoint not in output:
                raise RuntimeError(f"Missing launch checkpoint: {checkpoint}\n{output}")
    print("GUI launch passed: notification settings completed and an app window opened")


if __name__ == "__main__":
    check_launch(Path(sys.argv[1]))
