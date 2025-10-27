#!/usr/bin/env bash
set -euo pipefail
output=$(env \
  GPUUP_FORCE_STDIN=1 \
  GPUUP_PLAN_ONLY=1 \
  GPUUP_INTERACTIVE=1 \
  GPUUP_DRY_RUN=1 \
  ./gpuup.sh <<'INPUT'
y
INPUT
)
printf '%s
' "$output"
if ! grep -q "gpuup plan:" <<<"$output"; then
  echo "expected plan output" >&2
  exit 1
fi
if ! grep -q "install cuda-keyring" <<<"$output"; then
  echo "expected keyring install" >&2
  exit 1
fi
