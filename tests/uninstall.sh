#!/usr/bin/env bash
set -euo pipefail
output=$(env \
  GPUUP_FORCE_STDIN=1 \
  GPUUP_PLAN_ONLY=1 \
  GPUUP_INTERACTIVE=1 \
  GPUUP_DRY_RUN=1 \
  ./gpuup.sh <<'INPUT'
u
INPUT
)

printf '%s
' "$output"

grep -q "apt-get remove --purge" <<<"$output"
