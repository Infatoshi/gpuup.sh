#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
failures=0
for test in install customize verify uninstall; do
  echo "==> tests/${test}.sh"
  if "${HERE}/${test}.sh"; then
    echo "[pass] ${test}"
  else
    echo "[fail] ${test}" >&2
    failures=$((failures + 1))
  fi
  echo
done
if (( failures )); then
  echo "Tests failed: ${failures}" >&2
  exit 1
fi
