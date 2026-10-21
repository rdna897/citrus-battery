#!/bin/bash
# Render the real application views with fictional data; never reads live devices
# or the user's history. Sample rendering code is excluded from release builds.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c debug --product CitrusBattery
BIN="$(swift build -c debug --show-bin-path)/CitrusBattery"
"$BIN" --readme-screenshots "${1:-assets/screenshots}"
