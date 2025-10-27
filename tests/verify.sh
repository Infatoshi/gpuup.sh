#!/usr/bin/env bash
set -euo pipefail
output=$(env \
  GPUUP_FORCE_STDIN=1 \
  GPUUP_INTERACTIVE=1 \
  GPUUP_ASSUME_VERIFY_SUCCESS=1 \
  ./gpuup.sh <<'INPUT'
v
INPUT
)

printf '%s
' "$output"

grep -q "Simulating verification success" <<<"$output"
