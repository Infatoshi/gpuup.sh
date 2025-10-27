#!/usr/bin/env bash
set -Eeuo pipefail
TMP=$(mktemp -t gpuup-debug-XXXXXX)
trap 'rm -f "$TMP"' EXIT
curl -fsSL https://get.gpuup.sh > "$TMP"
chmod +x "$TMP"
export GPUUP_DEBUG=${GPUUP_DEBUG:-1}
export GPUUP_FORCE_STDIN=${GPUUP_FORCE_STDIN:-1}
export GPUUP_PROMPT_TIMEOUT=${GPUUP_PROMPT_TIMEOUT:-0}
LOG_PATH=${GPUUP_DEBUG_LOG:-$(pwd)/gpuup-debug.log}
"$TMP" "$@" 2>&1 | tee "$LOG_PATH"
echo "gpuup debug log saved to $LOG_PATH" >&2
