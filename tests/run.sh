#!/usr/bin/env bash
# Run the full local test suite. Skips what the machine can't run.
set -euo pipefail
cd "$(dirname "$0")/.."

if command -v shellcheck >/dev/null; then
  shellcheck configure.sh build/tor/entrypoint.sh tests/*.sh
  echo "PASS: shellcheck"
else
  echo "SKIP: shellcheck (not installed)"
fi

tests/test_configure.sh
tests/test_compose.sh
tests/test_e2e.sh

if python3 -c "import pytest, flask" 2>/dev/null; then
  python3 -m pytest build/dashboard/tests -q
else
  echo "SKIP: dashboard unit tests (pip install -r build/dashboard/requirements.txt pytest)"
fi

echo "All tests passed."
