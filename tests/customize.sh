#!/usr/bin/env bash
set -euo pipefail
output=$(env \
  GPUUP_FORCE_STDIN=1 \
  GPUUP_PLAN_ONLY=1 \
  GPUUP_INTERACTIVE=1 \
  GPUUP_DRY_RUN=1 \
  ./gpuup.sh <<'INPUT'
c
1
1
1

y
INPUT
)

printf '%s
' "$output"

grep -q "Select driver branch" <<<"$output"
grep -q "Select CUDA toolkit version" <<<"$output"
grep -q "gpuup plan:" <<<"$output"
