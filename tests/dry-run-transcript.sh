#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd "${HERE}/.." && pwd)
OUTPUT_DIR="${PROJECT_ROOT}/transcripts"
mkdir -p "$OUTPUT_DIR"

env GPUUP_FORCE_STDIN=1 \
    GPUUP_INTERACTIVE=1 \
    GPUUP_DRY_RUN=1 \
    ./gpuup.sh <<'INPUT' \
  | tee "$OUTPUT_DIR/interactive-dry-run.txt"
y
INPUT

echo "Transcript saved to ${OUTPUT_DIR}/interactive-dry-run.txt"
