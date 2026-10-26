#!/usr/bin/env python3
"""Exercise normal SwiftUI startup, notification settings, and a real app window."""

import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile


def check_launch(app: Path) -> None:
    app = app.resolve()
    executable = app / "Contents/MacOS/CitrusBattery"
    mode = os.environ.get("CITRUS_LAUNCH_CHECK", "gui")
    if mode not in {"gui", "notifications"}:
        raise ValueError(f"Unknown launch check mode: {mode}")
    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        stdout = directory / "stdout.log"
        stderr = directory / "stderr.log"
        pid_file = directory / "app.pid"
        # A history database of its own, so the check never touches the real one.
        history = directory / "history.sqlite"
        environment = dict(os.environ, CITRUS_GUI_SMOKE_TEST="1", CITRUS_SMOKE_PID_FILE=str(pid_file),
                           CITRUS_HISTORY_PATH=str(history))
        if mode == "gui":
            # Finder launches through LaunchServices, which sends SwiftUI its
            # initial open event. Running the executable directly can omit it.
            command = ["open", "-n", "-W", "--env", "CITRUS_GUI_SMOKE_TEST=1",
                       "--env", f"CITRUS_SMOKE_PID_FILE={pid_file}",
                       "--env", f"CITRUS_HISTORY_PATH={history}",
                       "--stdout", str(stdout), "--stderr", str(stderr), str(app)]
        else:
            command = [str(executable), "--notification-smoke-test"]
        with stdout.open("a") as out, stderr.open("a") as err:
            process = subprocess.Popen(command, env=environment, stdout=out, stderr=err)
            try:
                result = process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
                if pid_file.exists():
                    pid = int(pid_file.read_text())
                    try:
                        path = subprocess.check_output(["ps", "-p", str(pid), "-o", "comm="], stderr=subprocess.DEVNULL).decode().strip()
                        if path == str(executable):
                            os.kill(pid, signal.SIGTERM)
                    except (ProcessLookupError, subprocess.CalledProcessError):
                        pass
                raise RuntimeError(f"{mode} launch check timed out") from None
        output = stdout.read_text() + stderr.read_text()
        if result != 0:
            raise RuntimeError(f"App exited during {mode} launch (status {result}):\n{output}")
        checkpoints = ["Citrus notification settings check passed"]
        if mode == "gui":
            checkpoints.append("Citrus GUI launch check passed")
        for checkpoint in checkpoints:
            if checkpoint not in output:
                raise RuntimeError(f"Missing launch checkpoint: {checkpoint}\n{output}")
    print("GUI launch passed: notification settings completed and an app window opened" if mode == "gui"
          else "Notification startup passed (GUI rendering not exercised)")


if __name__ == "__main__":
    check_launch(Path(sys.argv[1]))
