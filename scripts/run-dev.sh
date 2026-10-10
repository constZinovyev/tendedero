#!/bin/bash
# Builds Tendedero for this Mac and the screen saver, then swaps the running
# app for the new one. It builds first and only then stops the running copy,
# so a failed build leaves the old app running.
# Usage: scripts/run-dev.sh [release]   (release: the universal build)
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh "${1:-dev}"
scripts/build-saver.sh --install
if pkill -x Tendedero; then
  # Waits just as long as the old copy takes to quit.
  for _ in $(seq 100); do pgrep -x Tendedero >/dev/null || break; sleep 0.05; done
fi
open build/Tendedero.app
