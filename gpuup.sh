#!/usr/bin/env bash
# gpuup.sh - NVIDIA driver and CUDA toolkit installer for Ubuntu 22.04/24.04

set -Eeuo pipefail

if [[ "${GPUUP_DEBUG:-0}" == "1" ]]; then
  set -x
fi

if [[ "${GPUUP_TRACE:-0}" == "1" ]]; then
  set -x
fi

trap 'gpuup_on_error ${LINENO}' ERR

gpuup_on_error() {
  local line="$1"
  printf 'gpuup: error on or near line %s\n' "$line" >&2
  printf 'gpuup: installation aborted\n' >&2
}

gpuup_warn() {
  printf 'gpuup: warning: %s\n' "$*" >&2
}

gpuup_log() {
  printf 'gpuup: %s\n' "$*"
}

gpuup_err() {
  printf 'gpuup: error: %s\n' "$*" >&2
  exit 1
}

gpuup_have() {
  command -v "$1" >/dev/null 2>&1
}

gpuup_run() {
  local dry=${GPUUP_DRY_RUN:-0}
  if (( dry )); then
    printf 'gpuup[dry-run]: %s\n' "$*"
    return 0
  fi
  if [[ "$*" == sudo*apt-get* ]]; then
    while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
      gpuup_warn "dpkg frontend lock held; waiting..."
      sleep 2
    done
  fi
  "$@"
}

gpuup_debug() {
  if (( GPUUP_DEBUG )); then
    printf 'gpuup[debug]: %s\n' "$*" >&2
  fi
}

gpuup_read_input() {
  local prompt="$1"
  local reply=""
  local use_tty=0
  local input_dev="/dev/stdin"

  if [[ -t 0 ]]; then
    use_tty=1
    input_dev="/dev/tty"
  fi

  if (( GPUUP_FORCE_STDIN )); then
    if [[ -r /dev/tty ]]; then
      use_tty=1
      input_dev="/dev/tty"
    else
      use_tty=0
      input_dev="/dev/stdin"
    fi
  fi

  if (( use_tty )); then
    if [[ -n "$prompt" ]]; then
      printf '%s ' "$prompt"
    fi
    if (( GPUUP_PROMPT_TIMEOUT > 0 )); then
      if ! IFS= read -r -t "$GPUUP_PROMPT_TIMEOUT" reply < "$input_dev"; then
        reply=""
      fi
    else
      if ! IFS= read -r reply < "$input_dev"; then
        reply=""
      fi
    fi
  else
    if [[ -n "$prompt" ]]; then
      printf '%s ' "$prompt"
    fi
    if (( GPUUP_PROMPT_TIMEOUT > 0 )); then
      if ! IFS= read -r -t "$GPUUP_PROMPT_TIMEOUT" reply; then
        reply=""
      fi
    else
      if ! IFS= read -r reply; then
        reply=""
      fi
    fi
  fi
  printf '%s' "$reply"
}

gpuup_prompt_yes_no() {
  local prompt="$1"
  local default="$2"
  local suffix="[y/n]"
  local def_lower="${default,,}"
  case "$def_lower" in
    y|yes) suffix="[Y/n]" ;;
    n|no) suffix="[y/N]" ;;
    "") suffix="[y/n]" ;;
  esac
  while true; do
    local input
    input=$(gpuup_read_input "$prompt $suffix ") || input=""
    input="${input,,}"
    if [[ -z "$input" && -n "$def_lower" ]]; then
      input="$def_lower"
    fi
    case "$input" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
    esac
    gpuup_warn "please answer y or n"
  done
}

gpuup_prompt_select() {
  local prompt="$1"
  local default="$2"
  shift 2
  local options=("$@")
  local count=${#options[@]}
  if (( count == 0 )); then
    gpuup_err "prompt_select called without options"
  fi
  while true; do
    gpuup_log "$prompt"
    local idx=1
    for opt in "${options[@]}"; do
      local marker=""
      if [[ "$opt" == "$default" ]]; then
        marker=" (default)"
      fi
      printf '  %d) %s%s\n' "$idx" "$opt" "$marker"
      idx=$((idx + 1))
    done
    local input
    input=$(gpuup_read_input "Selection [${default}]: ") || input=""
    if [[ "$input" == Selection* ]]; then
      input=""
    fi
    input="${input//[[:space:]]/}"
    if [[ -z "$input" ]]; then
      printf '%s' "$default"
      return
    fi
    if [[ "$input" =~ ^[0-9]+$ ]]; then
      local selection=$((input))
      if (( selection >= 1 && selection <= count )); then
        printf '%s' "${options[$((selection - 1))]}"
        return
      fi
    fi
    # allow direct value match
    local opt
    for opt in "${options[@]}"; do
      if [[ "${opt,,}" == "${input,,}" ]]; then
        printf '%s' "$opt"
        return
      fi
    done
    gpuup_warn "invalid selection: $input"
  done
}

gpuup_detect_uv() {
  if gpuup_have uv; then
    return 0
  fi
  if command -v uv >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

gpuup_detect_installed_versions() {
  GPUUP_INSTALLED_DRIVER="not detected"
  GPUUP_INSTALLED_CUDA="not detected"
  if gpuup_have nvidia-smi; then
    local smi_output driver
    if ! smi_output=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>&1); then
      if [[ "$smi_output" == *"Driver/library version mismatch"* ]]; then
        GPUUP_DRIVER_PENDING_REBOOT=1
        GPUUP_NVSMI_FAILURE_MESSAGE="$smi_output"
      elif [[ -z "$smi_output" ]]; then
        GPUUP_NVSMI_FAILURE_MESSAGE="nvidia-smi failed during driver detection."
      else
        GPUUP_NVSMI_FAILURE_MESSAGE="$smi_output"
      fi
    else
      driver=$(printf '%s\n' "$smi_output" | head -n1 | tr -d '[:space:]')
      if [[ -n "$driver" ]]; then
        GPUUP_INSTALLED_DRIVER="$driver"
      fi
    fi
  fi
  if gpuup_detect_nvcc_path && nvcc --version >/dev/null 2>&1; then
    local nvcc_line
    nvcc_line=$(nvcc --version 2>/dev/null | tail -n1)
    if [[ "$nvcc_line" =~ release[[:space:]]([0-9]+\.[0-9]+) ]]; then
      GPUUP_INSTALLED_CUDA="${BASH_REMATCH[1]}"
    else
      GPUUP_INSTALLED_CUDA="present"
    fi
  fi
}

GPUUP_SUPPORTED_CUDA=("13.0" "12.9" "12.8" "12.6" "12.4")
GPUUP_DEFAULT_CUDA="13.0"
GPUUP_DRIVER_BRANCHES=("580" "575" "570")
GPUUP_DEFAULT_DRIVER="580"

declare -A GPUUP_CUDA_MIN_DRIVER=(
  ["13.0"]=580.0
  ["12.4"]=550.54.14
  ["12.6"]=560.28.03
  ["12.8"]=570.26
  ["12.9"]=575.51.03
)

GPUUP_REQUESTED_CUDA="auto"
GPUUP_REQUESTED_DRIVER="auto"
GPUUP_MODULE_FLAVOR="closed"
GPUUP_FABRIC_PREF="auto"
GPUUP_PLAN_ONLY=0
GPUUP_DRY_RUN=0
GPUUP_VERIFY_ONLY=0
GPUUP_UNINSTALL=0
GPUUP_ASSUME_YES=0
GPUUP_NO_REBOOT=0
GPUUP_INTERACTIVE=0
GPUUP_USER_SPECIFIED=0
GPUUP_FORCE_INSTALL=0
GPUUP_INSTALLED_DRIVER=""
GPUUP_INSTALLED_CUDA=""
GPUUP_INTERACTIVE_DECISION="install"
GPUUP_FORCE_STDIN=${GPUUP_FORCE_STDIN:-0}
GPUUP_ASSUME_VERIFY_SUCCESS=${GPUUP_ASSUME_VERIFY_SUCCESS:-0}
GPUUP_TOOLKIT_PKG_OVERRIDE=""
GPUUP_PROMPT_TIMEOUT=${GPUUP_PROMPT_TIMEOUT:-0}
GPUUP_DEBUG=${GPUUP_DEBUG:-0}
GPUUP_MIN_DRIVER_REQUIRED=""

GPUUP_OS_ID=""
GPUUP_OS_VERSION=""
GPUUP_DISTRO_SLUG=""
GPUUP_ARCH=""
GPUUP_REPO_ARCH=""
GPUUP_IS_WSL=0
GPUUP_GPU_NAMES=()
GPUUP_GPU_CAPS=()
GPUUP_GPU_CLASSES=()
GPUUP_NEEDS_FABRIC=0
GPUUP_LEGACY_FLEET=0
GPUUP_DRIVER_PENDING_REBOOT=0
GPUUP_NVSMI_FAILURE_MESSAGE=""
GPUUP_EFFECTIVE_CUDA=""
GPUUP_EFFECTIVE_DRIVER=""
GPUUP_NVCC_PATH_NOTE=""
GPUUP_DRIVER_MODIFIED=0
GPUUP_SHELL_EXPORT_PATH=""

GPUUP_OS_RELEASE_PATH=${GPUUP_OS_RELEASE_PATH:-/etc/os-release}
GPUUP_PROC_VERSION_PATH=${GPUUP_PROC_VERSION_PATH:-/proc/version}
GPUUP_CUDA_HOME=${GPUUP_CUDA_HOME:-/usr/local/cuda}

gpuup_usage() {
  cat <<'EOUSAGE'
Usage: gpuup [options]

Options:
  --cuda {13.0|12.9|12.8|12.6|12.4|auto}   Select CUDA toolkit version (default auto)
  --driver {580|575|570|auto}              Select driver branch (default auto)
  --open-modules                      Install open kernel modules (default)
  --closed-modules                    Install proprietary kernel modules
  --fabric-manager                    Force Fabric Manager installation
  --no-fabric-manager                 Skip Fabric Manager even if heuristics match
  --plan                              Print detected state and planned actions, then exit
  --dry-run                           Echo commands without applying changes
  --yes                               Assume yes for prompts
  --no-reboot                         Suppress reboot suggestion
  --verify-only                       Validate nvcc and nvidia-smi only
  --uninstall                         Remove gpuup packages
  --help                              Show this help text
EOUSAGE
}

gpuup_parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cuda)
        shift || gpuup_err "--cuda requires a value"
        GPUUP_REQUESTED_CUDA="$1"
        GPUUP_USER_SPECIFIED=1
        GPUUP_FORCE_INSTALL=1
        ;;
      --driver)
        shift || gpuup_err "--driver requires a value"
        GPUUP_REQUESTED_DRIVER="$1"
        GPUUP_USER_SPECIFIED=1
        GPUUP_FORCE_INSTALL=1
        ;;
      --open-modules)
        GPUUP_MODULE_FLAVOR="open"
        GPUUP_USER_SPECIFIED=1
        GPUUP_FORCE_INSTALL=1
        ;;
      --closed-modules)
        GPUUP_MODULE_FLAVOR="closed"
        GPUUP_USER_SPECIFIED=1
        GPUUP_FORCE_INSTALL=1
        ;;
      --fabric-manager)
        GPUUP_FABRIC_PREF="force"
        GPUUP_USER_SPECIFIED=1
        GPUUP_FORCE_INSTALL=1
        ;;
      --no-fabric-manager)
        GPUUP_FABRIC_PREF="skip"
        GPUUP_USER_SPECIFIED=1
        GPUUP_FORCE_INSTALL=1
        ;;
      --plan)
        GPUUP_PLAN_ONLY=1
        GPUUP_USER_SPECIFIED=1
        ;;
      --dry-run)
        GPUUP_DRY_RUN=1
        GPUUP_USER_SPECIFIED=1
        ;;
      --yes)
        GPUUP_ASSUME_YES=1
        ;;
      --no-reboot)
        GPUUP_NO_REBOOT=1
        ;;
      --verify-only)
        GPUUP_VERIFY_ONLY=1
        GPUUP_USER_SPECIFIED=1
        ;;
      --uninstall)
        GPUUP_UNINSTALL=1
        GPUUP_USER_SPECIFIED=1
        ;;
      --interactive)
        GPUUP_INTERACTIVE=1
        ;;
      --non-interactive)
        GPUUP_INTERACTIVE=0
        ;;
      --help|-h)
        gpuup_usage
        exit 0
        ;;
      *)
        gpuup_err "unknown option: $1"
        ;;
    esac
    shift
  done

  if (( GPUUP_PLAN_ONLY )) && (( GPUUP_DRY_RUN )); then
    gpuup_warn "--plan implies read-only; ignoring --dry-run"
    GPUUP_DRY_RUN=0
  fi

  if (( GPUUP_VERIFY_ONLY )) && (( GPUUP_UNINSTALL )); then
    gpuup_err "--verify-only cannot be combined with --uninstall"
  fi

  if (( GPUUP_VERIFY_ONLY )) && (( GPUUP_PLAN_ONLY )); then
    gpuup_err "--verify-only cannot be combined with --plan"
  fi

  if (( GPUUP_INTERACTIVE )) && [[ ! -t 0 ]] && (( ! GPUUP_FORCE_STDIN )); then
    gpuup_warn "stdin is not a TTY; falling back to non-interactive mode"
    GPUUP_INTERACTIVE=0
  fi
}

gpuup_check_cuda_value() {
  local val="$1"
  if [[ "$val" == "auto" ]]; then
    return 0
  fi
  local v
  for v in "${GPUUP_SUPPORTED_CUDA[@]}"; do
    if [[ "$v" == "$val" ]]; then
      return 0
    fi
  done
  gpuup_err "unsupported CUDA version: $val"
}

gpuup_check_driver_value() {
  local val="$1"
  if [[ "$val" == "auto" ]]; then
    return 0
  fi
  local v
  for v in "${GPUUP_DRIVER_BRANCHES[@]}"; do
    if [[ "$v" == "$val" ]]; then
      return 0
    fi
  done
  gpuup_err "unsupported driver branch: $val"
}

gpuup_detect_os() {
  if [[ ! -r "$GPUUP_OS_RELEASE_PATH" ]]; then
    gpuup_err "cannot read ${GPUUP_OS_RELEASE_PATH}"
  fi
  # shellcheck disable=SC1090
  . "$GPUUP_OS_RELEASE_PATH"
  GPUUP_OS_ID="${ID:-}"
  GPUUP_OS_VERSION="${VERSION_ID:-}"
  if [[ "$GPUUP_OS_ID" != "ubuntu" ]]; then
    gpuup_err "unsupported distribution: ${GPUUP_OS_ID:-unknown}"
  fi
  case "$GPUUP_OS_VERSION" in
    22.04*) GPUUP_DISTRO_SLUG="ubuntu2204" ;;
    24.04*) GPUUP_DISTRO_SLUG="ubuntu2404" ;;
    *) gpuup_err "unsupported Ubuntu version: ${GPUUP_OS_VERSION:-unknown} (require 22.04 or 24.04)" ;;
  esac
}

gpuup_detect_arch() {
  if ! GPUUP_ARCH=$(dpkg --print-architecture); then
    gpuup_err "failed to detect architecture"
  fi
  case "$GPUUP_ARCH" in
    amd64) GPUUP_REPO_ARCH="x86_64" ;;
    arm64) GPUUP_REPO_ARCH="sbsa" ;;
    *) gpuup_err "unsupported architecture: $GPUUP_ARCH" ;;
  esac
}

gpuup_detect_wsl() {
  if [[ -r "$GPUUP_PROC_VERSION_PATH" ]] && grep -qi microsoft "$GPUUP_PROC_VERSION_PATH"; then
    GPUUP_IS_WSL=1
  else
    GPUUP_IS_WSL=0
  fi
}

gpuup_detect_nvcc_path() {
  if gpuup_have nvcc; then
    return 0
  fi
  if [[ -x "$GPUUP_CUDA_HOME/bin/nvcc" ]]; then
    export PATH="$GPUUP_CUDA_HOME/bin:${PATH}"
    if gpuup_have nvcc; then
      gpuup_warn "nvcc was not on PATH; temporarily adjusted"
      GPUUP_NVCC_PATH_NOTE="nvcc was not on PATH; PATH adjusted for session"
      return 0
    fi
  fi
  return 1
}

gpuup_driver_branch_from_version() {
  local version="$1"
  if [[ "$version" =~ ^([0-9]{3}) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

gpuup_driver_branch_ge() {
  local installed="$1"
  local required="$2"
  if [[ -z "$installed" || "$installed" == "not detected" ]]; then
    return 1
  fi
  local branch
  if ! branch=$(gpuup_driver_branch_from_version "$installed"); then
    return 1
  fi
  local have=$((10#$branch))
  local need=$((10#$required))
  if (( have >= need )); then
    return 0
  fi
  return 1
}

gpuup_version_ge() {
  local have="$1"
  local want="$2"
  if [[ -z "$have" || "$have" == "not detected" || "$have" == "present" ]]; then
    return 1
  fi
  local have_major have_minor want_major want_minor
  if [[ "$have" =~ ^([0-9]+)(\.([0-9]+))? ]]; then
    have_major=${BASH_REMATCH[1]}
    have_minor=${BASH_REMATCH[3]:-0}
  else
    return 1
  fi
  if [[ "$want" =~ ^([0-9]+)(\.([0-9]+))? ]]; then
    want_major=${BASH_REMATCH[1]}
    want_minor=${BASH_REMATCH[3]:-0}
  else
    return 0
  fi
  if (( have_major > want_major )); then
    return 0
  fi
  if (( have_major < want_major )); then
    return 1
  fi
  if (( have_minor >= want_minor )); then
    return 0
  fi
  return 1
}

gpuup_ensure_profile_exports() {
  # shellcheck disable=SC2016
  local snippet='export PATH=/usr/local/cuda/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH}'
  local target="/etc/profile.d/cuda.sh"
  if (( GPUUP_PLAN_ONLY )); then
    printf 'plan: ensure %s exports CUDA paths\n' "$target"
    return
  fi
  if grep -Fq "export PATH=/usr/local/cuda/bin:\$PATH" "$target" 2>/dev/null; then
    return
  fi
  if (( GPUUP_DRY_RUN )); then
    printf 'gpuup[dry-run]: would write %s\n' "$target"
    return
  fi
  printf '%s\n' "$snippet" | sudo tee "$target" >/dev/null
}

gpuup_short_circuit_success() {
  local nvcc_ok=0
  if gpuup_detect_nvcc_path && nvcc --version >/dev/null 2>&1; then
    nvcc_ok=1
  fi
  local smi_ok=0
  if gpuup_have nvidia-smi && nvidia-smi >/dev/null 2>&1; then
    smi_ok=1
  fi
  local driver_ok=1
  local cuda_ok=1
  if [[ "$GPUUP_EFFECTIVE_DRIVER" != "auto" && -n "$GPUUP_EFFECTIVE_DRIVER" ]]; then
    if ! gpuup_driver_branch_ge "$GPUUP_INSTALLED_DRIVER" "$GPUUP_EFFECTIVE_DRIVER"; then
      driver_ok=0
    fi
  fi
  if [[ "$GPUUP_EFFECTIVE_CUDA" != "auto" && -n "$GPUUP_EFFECTIVE_CUDA" ]]; then
    if ! gpuup_version_ge "$GPUUP_INSTALLED_CUDA" "$GPUUP_EFFECTIVE_CUDA"; then
      cuda_ok=0
    fi
  fi
  if (( nvcc_ok && smi_ok )); then
    if (( ! driver_ok || ! cuda_ok )); then
      gpuup_log "Existing driver/toolkit below recommended levels; continuing with installation."
      return 1
    fi
    if [[ -n "$GPUUP_NVCC_PATH_NOTE" ]]; then
      gpuup_offer_shell_exports
      gpuup_log "To use nvcc in this shell, run: export PATH=/usr/local/cuda/bin:\\$PATH"
    fi
    gpuup_log "CUDA toolkit and NVIDIA driver already present"
    nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null || true
    nvcc --version || true
    return 0
  fi
  return 1
}

gpuup_collect_gpus() {
  GPUUP_GPU_NAMES=()
  GPUUP_GPU_CAPS=()
  if gpuup_have nvidia-smi && nvidia-smi --query-gpu=name,compute_cap --format=csv,noheader >/tmp/gpuup.gpus 2>/dev/null; then
    while IFS=',' read -r name cap; do
      [[ -z "$name" ]] && continue
      name="${name#"${name%%[![:space:]]*}"}"
      name="${name%"${name##*[![:space:]]}"}"
      if [[ -n "$cap" ]]; then
        cap="${cap#"${cap%%[![:space:]]*}"}"
        cap="${cap%"${cap##*[![:space:]]}"}"
      else
        cap="unknown"
      fi
      GPUUP_GPU_NAMES+=("$name")
      GPUUP_GPU_CAPS+=("$cap")
    done < /tmp/gpuup.gpus
    rm -f /tmp/gpuup.gpus
  fi
  if ((${#GPUUP_GPU_NAMES[@]} == 0)); then
    if ! gpuup_have lspci; then
      if (( GPUUP_PLAN_ONLY || GPUUP_DRY_RUN )); then
        GPUUP_GPU_NAMES+=("undetected (plan mode)")
        GPUUP_GPU_CAPS+=("unknown")
        return
      fi
      gpuup_run sudo apt-get update
      gpuup_run sudo apt-get install -y pciutils
    fi
    mapfile -t GPUUP_GPU_NAMES < <(lspci -nn | grep -i nvidia || true)
    if ((${#GPUUP_GPU_CAPS[@]} < ${#GPUUP_GPU_NAMES[@]})); then
      local remaining=$(( ${#GPUUP_GPU_NAMES[@]} - ${#GPUUP_GPU_CAPS[@]} ))
      while (( remaining > 0 )); do
        GPUUP_GPU_CAPS+=("unknown")
        remaining=$((remaining - 1))
      done
    fi
  fi
  if ((${#GPUUP_GPU_NAMES[@]} == 0)); then
    GPUUP_GPU_NAMES+=("none detected")
    GPUUP_GPU_CAPS+=("unknown")
  fi
}

gpuup_fabric_pref_from_flag() {
  case "$GPUUP_FABRIC_PREF" in
    force) GPUUP_FABRIC_PREF=2 ;;
    skip) GPUUP_FABRIC_PREF=3 ;;
    *) GPUUP_FABRIC_PREF=1 ;;
  esac
}

gpuup_gpu_classify() {
  GPUUP_GPU_CLASSES=()
  GPUUP_NEEDS_FABRIC=0
  GPUUP_LEGACY_FLEET=0
  local idx=0
  for name in "${GPUUP_GPU_NAMES[@]}"; do
    local cls="unknown"
    local cap="${GPUUP_GPU_CAPS[$idx]:-unknown}"
    if [[ "$cap" =~ ^[0-9] ]]; then
      case "$cap" in
        5.*)
          cls="maxwell"
          GPUUP_LEGACY_FLEET=1
          ;;
        6.*)
          cls="pascal"
          GPUUP_LEGACY_FLEET=1
          ;;
        7.0*|7.2*)
          cls="volta"
          GPUUP_LEGACY_FLEET=1
          ;;
        7.5*)
          cls="turing"
          ;;
        8.0*|8.6*)
          cls="ampere"
          ;;
        8.9*)
          cls="ada"
          ;;
        9.*)
          cls="hopper"
          GPUUP_NEEDS_FABRIC=1
          ;;
        10.*)
          cls="blackwell"
          GPUUP_NEEDS_FABRIC=1
          ;;
        12.*)
          cls="blackwell-consumer"
          ;;
      esac
    fi
    if [[ "$cls" == "unknown" ]]; then
      case "$name" in
        *GB200*|*B200*|*GH200*|*"Grace Hopper"*|*Grace*|*H200*|*H100*|*HGX*|*Blackwell*)
          cls="hopper"
          GPUUP_NEEDS_FABRIC=1
          ;;
        *L40S*|*L40*|*L4*|*"RTX 6000 Ada"*|*"RTX 5000 Ada"*|*"RTX 4000 Ada"*)
          cls="ada"
          ;;
        *A100*|*A800*|*A30*|*A40*|*A16*|*A2*)
          cls="ampere"
          ;;
        *T4*|*"RTX 20"*|*"RTX 2060"*|*"RTX 2070"*|*"RTX 2080"*|*"GTX 16"*|*"TITAN RTX"*)
          cls="turing"
          ;;
        *V100*|*TITAN\ V*)
          cls="volta"
          GPUUP_LEGACY_FLEET=1
          ;;
        *P100*|*P40*|*P4*|*GTX\ 10*|*TITAN\ Xp*)
          cls="pascal"
          GPUUP_LEGACY_FLEET=1
          ;;
        *GTX\ 9*|*GTX\ 7*|*GTX\ 8*|*M60*|*M40*)
          cls="maxwell"
          GPUUP_LEGACY_FLEET=1
          ;;
        *K80*|*K40*|*K20*|*K520*|*GK*)
          cls="kepler"
        ;;
      esac
    fi
    GPUUP_GPU_CLASSES+=("$cls")
    idx=$((idx + 1))
  done

  local all_kepler=1
  local cls
  for cls in "${GPUUP_GPU_CLASSES[@]}"; do
    if [[ "$cls" != "kepler" ]]; then
      all_kepler=0
      break
    fi
  done
  if (( all_kepler )); then
    gpuup_err "Kepler-only GPUs detected; use legacy R470 drivers"
  fi

  if (( GPUUP_FABRIC_PREF == 2 )); then
    GPUUP_NEEDS_FABRIC=1
  elif (( GPUUP_FABRIC_PREF == 3 )); then
    GPUUP_NEEDS_FABRIC=0
  fi
}

gpuup_set_default_versions() {
  if (( GPUUP_LEGACY_FLEET )); then
    GPUUP_DEFAULT_CUDA="12.9"
    GPUUP_DEFAULT_DRIVER="575"
  else
    GPUUP_DEFAULT_CUDA="13.0"
    GPUUP_DEFAULT_DRIVER="580"
  fi
}

gpuup_interactive_print_summary() {
  gpuup_log "Detected environment:"
  printf '  OS: Ubuntu %s (%s)\n' "$GPUUP_OS_VERSION" "$GPUUP_ARCH"
  printf '  GPUs:\n'
  local idx=0
  for name in "${GPUUP_GPU_NAMES[@]}"; do
    local cls="${GPUUP_GPU_CLASSES[$idx]:-unknown}"
    local cap="${GPUUP_GPU_CAPS[$idx]:-unknown}"
    printf '    - %s [%s, cc=%s]\n' "$name" "$cls" "$cap"
    idx=$((idx + 1))
  done
  printf '  Installed driver: %s\n' "$GPUUP_INSTALLED_DRIVER"
  printf '  Installed CUDA: %s\n' "$GPUUP_INSTALLED_CUDA"
  if (( GPUUP_IS_WSL )); then
    printf '  Environment: WSL2 (driver managed by Windows)\n'
  fi
}

gpuup_interactive_customize() {
  local recommended_cuda="$1"
  local recommended_driver="$2"
  local selected_driver="$recommended_driver"
  local selected_cuda="$recommended_cuda"
  local selected_module="$GPUUP_MODULE_FLAVOR"

  if (( ! GPUUP_IS_WSL )); then
    selected_driver=$(gpuup_prompt_select "Select driver branch" "$recommended_driver" "${GPUUP_DRIVER_BRANCHES[@]}")
    selected_module=$(gpuup_prompt_select "Select kernel module flavor" "$GPUUP_MODULE_FLAVOR" "open" "closed")
  fi
  selected_cuda=$(gpuup_prompt_select "Select CUDA toolkit version" "$recommended_cuda" "${GPUUP_SUPPORTED_CUDA[@]}")

  if (( ! GPUUP_IS_WSL )); then
    local fabric_default="n"
    if (( GPUUP_NEEDS_FABRIC )); then
      fabric_default="y"
    fi
    if gpuup_prompt_yes_no "Install NVIDIA Fabric Manager when applicable?" "$fabric_default"; then
      GPUUP_NEEDS_FABRIC=1
    else
      GPUUP_NEEDS_FABRIC=0
    fi
  fi

  GPUUP_REQUESTED_DRIVER="$selected_driver"
  GPUUP_REQUESTED_CUDA="$selected_cuda"
  GPUUP_MODULE_FLAVOR="$selected_module"
}

gpuup_branch_floor_version() {
  local branch="$1"
  case "$branch" in
    580) printf '580.0' ;;
    575) printf '575.0' ;;
    570) printf '570.0' ;;
    *) return 1 ;;
  esac
}

gpuup_selection_supported() {
  local cuda="$1"
  local driver="$2"
  if [[ "$driver" == "auto" ]]; then
    return 0
  fi
  local min="${GPUUP_CUDA_MIN_DRIVER[$cuda]:-}"
  if [[ -z "$min" ]]; then
    return 0
  fi
  local floor
  if ! floor=$(gpuup_branch_floor_version "$driver"); then
    return 1
  fi
  if dpkg --compare-versions "$floor" ge "$min"; then
    return 0
  fi
  return 1
}

gpuup_interactive_flow() {
  gpuup_interactive_print_summary

  local prev_cuda="$GPUUP_REQUESTED_CUDA"
  local prev_driver="$GPUUP_REQUESTED_DRIVER"
  local warn_count=0

  GPUUP_REQUESTED_CUDA="auto"
  GPUUP_REQUESTED_DRIVER="auto"
  gpuup_choose_cuda_version
  local recommended_cuda="$GPUUP_EFFECTIVE_CUDA"
  gpuup_choose_driver_branch
  local recommended_driver="$GPUUP_EFFECTIVE_DRIVER"

  GPUUP_REQUESTED_CUDA="$prev_cuda"
  GPUUP_REQUESTED_DRIVER="$prev_driver"

  local noninteractive_pipe=0
  if [[ "${BASH_SOURCE[0]:-}" == "main" ]] && [[ ! -t 0 ]] && [[ ! -t 1 ]]; then
    noninteractive_pipe=1
  fi

  if (( noninteractive_pipe )); then
    GPUUP_REQUESTED_CUDA="$recommended_cuda"
    GPUUP_REQUESTED_DRIVER="$recommended_driver"
    GPUUP_FORCE_INSTALL=1
    GPUUP_INTERACTIVE_DECISION="install"
    gpuup_log "No response detected; continuing with recommended installation."
    return
  fi

  while true; do
    local prompt
    if (( GPUUP_IS_WSL )); then
      prompt="Install or update CUDA toolkit ${recommended_cuda} (WSL toolkit only)?"
    else
      prompt="Install or update driver ${recommended_driver} (${GPUUP_MODULE_FLAVOR}) with CUDA ${recommended_cuda}?"
    fi
    local choice default_action="y"
    choice=$(gpuup_read_input "$prompt [Y]es/[C]ustomize/[V]erify/[U]ninstall/[Q]uit: ") || choice=""
    choice="${choice,,}"
    choice="${choice//[[:space:]]/}"
    if [[ -z "$choice" ]]; then
      choice="$default_action"
    fi
    case "$choice" in
      ""|y|yes)
        GPUUP_REQUESTED_CUDA="$recommended_cuda"
        GPUUP_REQUESTED_DRIVER="$recommended_driver"
        GPUUP_FORCE_INSTALL=1
        GPUUP_INTERACTIVE_DECISION="install"
        break
        ;;
      c|custom|configure)
        gpuup_interactive_customize "$recommended_cuda" "$recommended_driver"
        gpuup_choose_cuda_version
        gpuup_choose_driver_branch
        if gpuup_selection_supported "$GPUUP_EFFECTIVE_CUDA" "$GPUUP_EFFECTIVE_DRIVER"; then
          :
        else
          gpuup_warn "Selected CUDA ${GPUUP_EFFECTIVE_CUDA} requires a newer driver branch."
          GPUUP_REQUESTED_CUDA="$recommended_cuda"
          GPUUP_REQUESTED_DRIVER="$recommended_driver"
          continue
        fi
        local summary
        if (( GPUUP_IS_WSL )); then
          summary=$(printf 'Proceed with CUDA %s?' "$GPUUP_EFFECTIVE_CUDA")
        else
          summary=$(printf 'Proceed with driver %s (%s) and CUDA %s?' "$GPUUP_EFFECTIVE_DRIVER" "$GPUUP_MODULE_FLAVOR" "$GPUUP_EFFECTIVE_CUDA")
        fi
        if gpuup_prompt_yes_no "$summary" "y"; then
        GPUUP_FORCE_INSTALL=1
        GPUUP_INTERACTIVE_DECISION="install"
        break
        fi
        ;;
      v|verify)
        GPUUP_VERIFY_ONLY=1
        GPUUP_INTERACTIVE_DECISION="verify"
        return
        ;;
      u|uninstall|remove)
        GPUUP_UNINSTALL=1
        GPUUP_INTERACTIVE_DECISION="uninstall"
        return
        ;;
      q|quit|exit)
        gpuup_log "Exiting without changes."
        exit 0
        ;;
      *)
        warn_count=$((warn_count + 1))
        if (( warn_count > 3 )); then
          gpuup_log "No response detected; continuing with recommended installation."
          GPUUP_REQUESTED_CUDA="$recommended_cuda"
          GPUUP_REQUESTED_DRIVER="$recommended_driver"
          GPUUP_FORCE_INSTALL=1
          GPUUP_INTERACTIVE_DECISION="install"
          break
        fi
        gpuup_warn "please choose Y, C, V, U, or Q"
        ;;
    esac
  done
}

gpuup_choose_cuda_version() {
  if [[ "$GPUUP_REQUESTED_CUDA" != "auto" ]]; then
    GPUUP_EFFECTIVE_CUDA="$GPUUP_REQUESTED_CUDA"
    return
  fi
  GPUUP_EFFECTIVE_CUDA="$GPUUP_DEFAULT_CUDA"
}

gpuup_choose_driver_branch() {
  if [[ "$GPUUP_REQUESTED_DRIVER" != "auto" ]]; then
    GPUUP_EFFECTIVE_DRIVER="$GPUUP_REQUESTED_DRIVER"
    return
  fi
  GPUUP_EFFECTIVE_DRIVER="$GPUUP_DEFAULT_DRIVER"
}

gpuup_verify_driver_cuda_matrix() {
  local cuda="$GPUUP_EFFECTIVE_CUDA"
  local min_driver="${GPUUP_CUDA_MIN_DRIVER[$cuda]}"
  if [[ -z "$min_driver" ]]; then
    gpuup_warn "no compatibility matrix entry for CUDA ${cuda}; skipping driver minimum check"
    return
  fi
  GPUUP_MIN_DRIVER_REQUIRED="$min_driver"
  if [[ "$GPUUP_EFFECTIVE_DRIVER" == "auto" ]]; then
    return
  fi
  local floor
  if ! floor=$(gpuup_branch_floor_version "$GPUUP_EFFECTIVE_DRIVER"); then
    gpuup_err "unknown driver branch ${GPUUP_EFFECTIVE_DRIVER}"
  fi
  if dpkg --compare-versions "$floor" lt "$min_driver"; then
    gpuup_err "CUDA ${cuda} requires driver >=${min_driver}; branch ${GPUUP_EFFECTIVE_DRIVER} is insufficient"
  fi
}

gpuup_package_for_driver() {
  local branch="$1"
  local flavor="$2"
  if [[ "$flavor" == "open" ]]; then
    case "$branch" in
      580) printf 'nvidia-open-580' ;;
      575) printf 'nvidia-open-575' ;;
      570) printf 'nvidia-open-570' ;;
      *) gpuup_err "unsupported driver branch ${branch}" ;;
    esac
  else
    case "$branch" in
      580) printf 'cuda-drivers-580' ;;
      575) printf 'cuda-drivers-575' ;;
      570) printf 'cuda-drivers-570' ;;
      *) gpuup_err "unsupported driver branch ${branch}" ;;
    esac
  fi
}

gpuup_package_for_fabric() {
  local branch="$1"
  local flavor="$2"
  if (( ! GPUUP_NEEDS_FABRIC )); then
    return
  fi
  if [[ "$flavor" == "open" ]]; then
    case "$branch" in
      580) printf 'nvidia-fabricmanager-580' ;;
      575) printf 'nvidia-fabricmanager-575' ;;
      570) printf 'nvidia-fabricmanager-570' ;;
    esac
  else
    case "$branch" in
      580) printf 'cuda-drivers-fabricmanager-580' ;;
      575) printf 'cuda-drivers-fabricmanager-575' ;;
      570) printf 'cuda-drivers-fabricmanager-570' ;;
    esac
  fi
}

gpuup_package_for_toolkit() {
  if [[ -n "$GPUUP_TOOLKIT_PKG_OVERRIDE" ]]; then
    printf '%s' "$GPUUP_TOOLKIT_PKG_OVERRIDE"
    return
  fi
  local cuda="$1"
  printf 'cuda-toolkit-%s' "${cuda//./-}"
}

gpuup_policy_candidate() {
  local pkg="$1"
  local candidate
  candidate=$({ apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ {print $2; exit}'; } || true)
  printf '%s' "$candidate"
}

gpuup_handle_driver_failure() {
  local pkg="$1"
  local min_required="$GPUUP_MIN_DRIVER_REQUIRED"
  if [[ "$GPUUP_INSTALLED_DRIVER" != "not detected" && -n "$min_required" ]]; then
    if dpkg --compare-versions "$GPUUP_INSTALLED_DRIVER" ge "$min_required"; then
      gpuup_warn "driver $pkg could not be installed, but existing driver $GPUUP_INSTALLED_DRIVER satisfies minimum $min_required; continuing with toolkit only"
      return
    fi
  fi
  gpuup_err "failed to install NVIDIA driver package ($pkg)"
}

gpuup_cuda_keyring_url() {
  printf 'https://developer.download.nvidia.com/compute/cuda/repos/%s/%s/cuda-keyring_1.1-1_all.deb' \
    "$GPUUP_DISTRO_SLUG" "$GPUUP_REPO_ARCH"
}

gpuup_install_cuda_keyring() {
  if dpkg -s cuda-keyring >/dev/null 2>&1; then
    return
  fi
  local url
  url=$(gpuup_cuda_keyring_url)
  if (( GPUUP_PLAN_ONLY )); then
    printf 'plan: install cuda-keyring from %s\n' "$url"
    return
  fi
  if (( GPUUP_DRY_RUN )); then
    printf 'gpuup[dry-run]: would install cuda-keyring from %s\n' "$url"
    return
  fi
  gpuup_log "installing cuda-keyring"
  gpuup_run sudo apt-get update
  gpuup_run sudo apt-get install -y curl ca-certificates
  local tmpdeb
  tmpdeb=$(mktemp)
  gpuup_run curl -fsSL "$url" -o "$tmpdeb"
  gpuup_run sudo dpkg -i "$tmpdeb"
  rm -f "$tmpdeb"
}

gpuup_apt_update() {
  if (( GPUUP_PLAN_ONLY )); then
    printf 'plan: apt-get update\n'
    return
  fi
  gpuup_run sudo apt-get update
}

gpuup_apt_install() {
  local packages=("$@")
  if (( ${#packages[@]} == 0 )); then
    return
  fi
  gpuup_debug "apt install ${packages[*]}"
  if (( GPUUP_PLAN_ONLY )); then
    printf 'plan: apt-get install -y %s\n' "${packages[*]}"
    return
  fi
  if (( GPUUP_DRY_RUN )); then
    printf 'gpuup[dry-run]: would apt-get install -y %s\n' "${packages[*]}"
    return
  fi
  local cmd=(sudo apt-get install -y)
  if (( GPUUP_ASSUME_YES )); then
    cmd=(sudo DEBIAN_FRONTEND=noninteractive apt-get install -y)
  fi
  gpuup_run "${cmd[@]}" "${packages[@]}"
}

gpuup_add_prereqs() {
  local pkgs=(build-essential dkms "linux-headers-$(uname -r)" pciutils)
  gpuup_apt_install "${pkgs[@]}"
}

gpuup_blacklist_nouveau() {
  if ! lsmod | grep -w nouveau >/dev/null 2>&1; then
    return
  fi
  local conf="/etc/modprobe.d/blacklist-nouveau.conf"
  local content=$'blacklist nouveau\noptions nouveau modeset=0'
  if (( GPUUP_PLAN_ONLY )); then
    printf 'plan: write %s and run update-initramfs\n' "$conf"
    return
  fi
  if (( GPUUP_DRY_RUN )); then
    printf 'gpuup[dry-run]: would write %s and run update-initramfs\n' "$conf"
    return
  fi
  printf '%s\n' "$content" | sudo tee "$conf" >/dev/null
  gpuup_run sudo update-initramfs -u
}

gpuup_resolve_toolkit_version_runtime() {
  if (( GPUUP_PLAN_ONLY || GPUUP_DRY_RUN )); then
    return
  fi
  local candidates=()
  if [[ "$GPUUP_REQUESTED_CUDA" == "auto" ]]; then
    case "$GPUUP_EFFECTIVE_DRIVER" in
      580) candidates=("13.0" "12.9" "12.8" "12.6" "12.4") ;;
      575) candidates=("12.9" "12.8" "12.6" "12.4") ;;
      570) candidates=("12.8" "12.6" "12.4") ;;
      *) candidates=("13.0" "12.9" "12.8" "12.6" "12.4") ;;
    esac
  else
    candidates=("$GPUUP_REQUESTED_CUDA")
  fi
  local version
  for version in "${candidates[@]}"; do
    local pkg
    pkg=$(gpuup_package_for_toolkit "$version")
    gpuup_debug "probing toolkit package $pkg"
    if (( GPUUP_DEBUG )); then
      { apt-cache policy "$pkg" 2>&1 | sed 's/^/gpuup[debug]: /'; } >&2 || true
    fi
    local candidate
    candidate=$(gpuup_policy_candidate "$pkg")
    gpuup_debug "candidate for $pkg: ${candidate:-<none>}"
    if [[ -n "$candidate" && "$candidate" != "(none)" ]]; then
      GPUUP_EFFECTIVE_CUDA="$version"
      return
    fi
  done
  local meta_candidate
  meta_candidate=$(gpuup_policy_candidate cuda-toolkit)
  gpuup_debug "candidate for cuda-toolkit meta: ${meta_candidate:-<none>}"
  if [[ -n "$meta_candidate" && "$meta_candidate" != "(none)" ]]; then
    gpuup_debug "using cuda-toolkit meta package ($meta_candidate)"
    if (( GPUUP_DEBUG )); then
      { apt-cache policy cuda-toolkit 2>&1 | sed 's/^/gpuup[debug]: /'; } >&2 || true
    fi
    GPUUP_TOOLKIT_PKG_OVERRIDE="cuda-toolkit"
    local base="${meta_candidate%%-*}"
    if [[ "$base" =~ ^([0-9]+)\.([0-9]+) ]]; then
      GPUUP_EFFECTIVE_CUDA="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
    else
      GPUUP_EFFECTIVE_CUDA="legacy"
    fi
    return
  fi
  if [[ "$GPUUP_REQUESTED_CUDA" == "auto" ]]; then
    gpuup_err "no supported CUDA toolkit packages (13.0, 12.9, 12.8, 12.6, 12.4) available in CUDA repository"
  else
    gpuup_err "requested CUDA toolkit $GPUUP_REQUESTED_CUDA unavailable in repository"
  fi
}

gpuup_resolve_driver_branch_runtime() {
  if (( GPUUP_PLAN_ONLY || GPUUP_DRY_RUN || GPUUP_IS_WSL )); then
    return
  fi
  local branches=()
  if [[ "$GPUUP_REQUESTED_DRIVER" == "auto" ]]; then
    branches=("$GPUUP_DEFAULT_DRIVER" "575" "570")
  else
    branches=("$GPUUP_REQUESTED_DRIVER")
  fi
  if gpuup_have nvidia-smi; then
    local installed smi_output
    if smi_output=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null); then
      installed=$(printf '%s\n' "$smi_output" | head -n1 | tr -d '[:space:]')
      if [[ -n "$installed" && "$installed" =~ ^([0-9]{3}) ]]; then
        local branch_hint="${BASH_REMATCH[1]}"
        case "$branch_hint" in
          58[0-9]|57[0-9])
            local seen=0
            local existing
            for existing in "${branches[@]}"; do
              if [[ "$existing" == "$branch_hint" ]]; then
                seen=1
                break
              fi
            done
            if (( ! seen )); then
              local hint_val=$((10#$branch_hint))
              local default_val=$((10#$GPUUP_DEFAULT_DRIVER))
              if (( hint_val >= default_val )); then
                branches=("$branch_hint" "${branches[@]}")
              else
                branches+=("$branch_hint")
              fi
            fi
            ;;
        esac
      fi
    fi
  fi
  local branch
  for branch in "${branches[@]}"; do
    local pkg
    pkg=$(gpuup_package_for_driver "$branch" "$GPUUP_MODULE_FLAVOR")
    gpuup_debug "probing driver package $pkg"
    if (( GPUUP_DEBUG )); then
      apt-cache policy "$pkg" 2>&1 | sed 's/^/gpuup[debug]: /' >&2 || true
    fi
    local candidate
    candidate=$(gpuup_policy_candidate "$pkg")
    gpuup_debug "candidate for $pkg: ${candidate:-<none>}"
    if [[ -n "$candidate" && "$candidate" != "(none)" ]]; then
      GPUUP_EFFECTIVE_DRIVER="$branch"
      return
    fi
  done
  if [[ "$GPUUP_REQUESTED_DRIVER" == "auto" ]]; then
    gpuup_err "no supported driver branches (580, 575, 570) available in CUDA repository"
  else
    gpuup_err "requested driver branch $GPUUP_REQUESTED_DRIVER unavailable in repository"
  fi
}

gpuup_install_driver_toolkit() {
  gpuup_install_cuda_keyring
  gpuup_apt_update
  gpuup_resolve_driver_branch_runtime
  gpuup_resolve_toolkit_version_runtime
  gpuup_verify_driver_cuda_matrix

  local driver_pkg
  driver_pkg=$(gpuup_package_for_driver "$GPUUP_EFFECTIVE_DRIVER" "$GPUUP_MODULE_FLAVOR")
  local toolkit_pkg
  toolkit_pkg=$(gpuup_package_for_toolkit "$GPUUP_EFFECTIVE_CUDA")
  local fabric_pkg
  fabric_pkg=$(gpuup_package_for_fabric "$GPUUP_EFFECTIVE_DRIVER" "$GPUUP_MODULE_FLAVOR") || true

  gpuup_debug "effective driver branch: $GPUUP_EFFECTIVE_DRIVER ($driver_pkg)"
  gpuup_debug "effective CUDA version: $GPUUP_EFFECTIVE_CUDA ($toolkit_pkg)"
  if [[ -n "$fabric_pkg" ]]; then
    gpuup_debug "fabric manager package: $fabric_pkg"
  fi

  if (( GPUUP_IS_WSL )); then
    if [[ "$GPUUP_MODULE_FLAVOR" == "closed" ]]; then
      gpuup_warn "WSL detected; skipping driver install despite --closed-modules"
    fi
    gpuup_warn "WSL detected; install Windows NVIDIA driver separately"
    gpuup_apt_install "$toolkit_pkg"
    return
  fi

  gpuup_add_prereqs
  gpuup_blacklist_nouveau
  local driver_installed=0
  if gpuup_apt_install "$driver_pkg"; then
    driver_installed=1
  else
    if [[ "$GPUUP_MODULE_FLAVOR" == "open" ]]; then
      gpuup_warn "installing $driver_pkg failed; retrying with proprietary modules"
      GPUUP_MODULE_FLAVOR="closed"
      driver_pkg=$(gpuup_package_for_driver "$GPUUP_EFFECTIVE_DRIVER" "$GPUUP_MODULE_FLAVOR")
      if gpuup_apt_install "$driver_pkg"; then
        driver_installed=1
      else
        gpuup_handle_driver_failure "$driver_pkg"
      fi
    else
      gpuup_handle_driver_failure "$driver_pkg"
    fi
  fi
  toolkit_pkg=$(gpuup_package_for_toolkit "$GPUUP_EFFECTIVE_CUDA")
  gpuup_apt_install "$toolkit_pkg"
  fabric_pkg=$(gpuup_package_for_fabric "$GPUUP_EFFECTIVE_DRIVER" "$GPUUP_MODULE_FLAVOR") || true
  if [[ -n "$fabric_pkg" ]]; then
    gpuup_apt_install "$fabric_pkg"
    if (( ! GPUUP_PLAN_ONLY && ! GPUUP_DRY_RUN )); then
      gpuup_run sudo systemctl enable --now nvidia-fabricmanager || true
    fi
  fi
  if (( driver_installed )); then
    GPUUP_DRIVER_MODIFIED=1
  fi
}

gpuup_uninstall() {
  local pkgs=(
    cuda-toolkit-13-0 cuda-toolkit-12-9 cuda-toolkit-12-8 cuda-toolkit-12-6 cuda-toolkit-12-4
    cuda-drivers cuda-drivers-580 cuda-drivers-575 cuda-drivers-570
    cuda-drivers-fabricmanager-580 cuda-drivers-fabricmanager-575 cuda-drivers-fabricmanager-570
    nvidia-open nvidia-open-580 nvidia-open-575 nvidia-open-570
    nvidia-driver-580 nvidia-driver-575 nvidia-driver-570
    nvidia-fabricmanager nvidia-fabricmanager-580 nvidia-fabricmanager-575 nvidia-fabricmanager-570
  )
  if (( GPUUP_PLAN_ONLY )); then
    printf 'plan: apt-get remove --purge %s\n' "${pkgs[*]}"
    return
  fi
  if (( GPUUP_DRY_RUN )); then
    printf 'gpuup[dry-run]: would apt-get remove --purge %s\n' "${pkgs[*]}"
    return
  fi
  local cmd=(sudo apt-get remove --purge)
  if (( GPUUP_ASSUME_YES )); then
    cmd+=("-y")
  fi
  gpuup_run "${cmd[@]}" "${pkgs[@]}"
}

gpuup_verify_post() {
  local nvcc_output="" smi_output=""
  local have_nvcc=0 have_smi=0

  if nvcc_output=$(nvcc --version 2>&1); then
    have_nvcc=1
  else
    have_nvcc=0
  fi

  if smi_output=$(nvidia-smi 2>&1); then
    have_smi=1
  else
    have_smi=0
  fi

  if (( have_nvcc )); then
    printf '%s\n' "$nvcc_output"
  else
    gpuup_warn "nvcc not available"
    if [[ -n "$GPUUP_SHELL_EXPORT_PATH" ]]; then
      gpuup_log "Run: source $GPUUP_SHELL_EXPORT_PATH (or open a new shell) to load CUDA PATH exports."
    else
      gpuup_log "Run: export PATH=/usr/local/cuda/bin:\$PATH (or open a new shell) to load CUDA PATH exports."
    fi
  fi

  if (( have_smi )); then
    printf '%s\n' "$smi_output"
  else
    gpuup_warn "nvidia-smi not available (driver may need reboot)"
  fi

  if (( have_nvcc && have_smi )); then
    return 0
  fi

  if (( ! have_smi )) && (( ! GPUUP_NO_REBOOT )); then
    gpuup_warn "reboot and rerun gpuup --verify-only after modules load"
  fi

  return 1
}

gpuup_offer_uv() {
  if (( ! GPUUP_INTERACTIVE )); then
    return
  fi
  if [[ "$GPUUP_INTERACTIVE_DECISION" != "install" ]]; then
    return
  fi
  if gpuup_detect_uv; then
    return
  fi
  gpuup_log "uv command not detected."
  if ! gpuup_prompt_yes_no "Install uv (recommended for managing GPUup tooling)?" "y"; then
    gpuup_log "Skipping uv installation."
    return
  fi
  local install_cmd='curl -LsSf https://astral.sh/uv/install.sh | sh'
  if (( GPUUP_DRY_RUN )); then
    printf 'gpuup[dry-run]: %s\n' "$install_cmd"
    return
  fi
  gpuup_log "Installing uv..."
  if bash -lc "$install_cmd"; then
    if gpuup_detect_uv; then
      uv --version || true
    else
      gpuup_warn "uv installer completed but uv not found on PATH; restart the shell or add ~/.local/bin to PATH."
    fi
  else
    gpuup_warn "uv installation command failed"
  fi
}

gpuup_offer_shell_exports() {
  local cuda_bin="/usr/local/cuda/bin"
  local cuda_lib="/usr/local/cuda/lib64"
  if [[ ! -d "$cuda_bin" ]]; then
    return
  fi

  local home_dir="${GPUUP_TARGET_HOME:-$HOME}"
  local rc_candidates=("$home_dir/.bashrc" "$home_dir/.profile" "$home_dir/.zshrc")
  local target=""
  for rc in "${rc_candidates[@]}"; do
    if [[ -f "$rc" ]]; then
      target="$rc"
      break
    fi
  done
  if [[ -z "$target" ]]; then
    target="$home_dir/.bashrc"
    if [[ ! -e "$target" ]]; then
      gpuup_log "Creating $target"
      touch "$target"
    fi
  fi
  GPUUP_SHELL_EXPORT_PATH="$target"

  local marker="# gpuup CUDA exports"
  local legacy_exports=0
  if [[ -f "$target" ]] && grep -Eq '/usr/local/cuda-[0-9]+\.[0-9]+' "$target"; then
    legacy_exports=1
  fi
  if ! grep -Fq "$marker" "$target" 2>/dev/null; then
    gpuup_log "Appending CUDA PATH exports to $target"
    cat <<'EOS' >> "$target"

# gpuup CUDA exports (added by gpuup.sh)
export PATH=/usr/local/cuda/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
EOS
  else
    gpuup_log "CUDA exports already present in $target"
  fi

  if [[ ":$PATH:" != *":/usr/local/cuda/bin:"* ]]; then
    export PATH="/usr/local/cuda/bin:$PATH"
  fi
  if [[ -z "${LD_LIBRARY_PATH:-}" ]]; then
    export LD_LIBRARY_PATH="/usr/local/cuda/lib64"
  elif [[ ":$LD_LIBRARY_PATH:" != *":/usr/local/cuda/lib64:"* ]]; then
    export LD_LIBRARY_PATH="/usr/local/cuda/lib64:$LD_LIBRARY_PATH"
  fi

  hash -r 2>/dev/null || true

  if (( legacy_exports )); then
    gpuup_warn "Detected legacy CUDA exports in $target; remove any /usr/local/cuda-*/ entries to prevent stale nvcc versions."
  fi

  if gpuup_have nvcc; then
    nvcc --version || true
  else
    gpuup_warn "nvcc still not on PATH; open a new shell session or source $target manually."
  fi

  local alt_rc=""
  local zsh_rc="$home_dir/.zshrc"
  if [[ "$GPUUP_SHELL_EXPORT_PATH" != "$zsh_rc" && -f "$zsh_rc" ]]; then
    alt_rc="$zsh_rc"
  fi

  if [[ -n "$alt_rc" ]]; then
    gpuup_log "Run: source $GPUUP_SHELL_EXPORT_PATH or source $alt_rc (or open a new shell) to refresh CUDA PATH exports."
  else
    gpuup_log "Run: source $GPUUP_SHELL_EXPORT_PATH (or open a new shell) to refresh CUDA PATH exports."
  fi
}

gpuup_plan_report() {
  printf 'gpuup plan:\n'
  printf '  distro: %s (%s)\n' "$GPUUP_OS_VERSION" "$GPUUP_DISTRO_SLUG"
  printf '  arch: %s (%s)\n' "$GPUUP_ARCH" "$GPUUP_REPO_ARCH"
  printf '  wsl: %s\n' "$GPUUP_IS_WSL"
  printf '  gpus:\n'
  local idx=0
  for name in "${GPUUP_GPU_NAMES[@]}"; do
    local cls="${GPUUP_GPU_CLASSES[$idx]:-unknown}"
    local cap="${GPUUP_GPU_CAPS[$idx]:-unknown}"
    printf '    - name: %s\n      class: %s\n      compute_cap: %s\n' "$name" "$cls" "$cap"
    idx=$((idx + 1))
  done
  printf '  driver_branch: %s\n' "$GPUUP_EFFECTIVE_DRIVER"
  printf '  module_flavor: %s\n' "$GPUUP_MODULE_FLAVOR"
  printf '  fabric_manager: %s\n' "$([[ "$GPUUP_NEEDS_FABRIC" -eq 1 ]] && printf 'planned' || printf 'skipped')"
  printf '  cuda_version: %s\n' "$GPUUP_EFFECTIVE_CUDA"
  if [[ -n "$GPUUP_NVCC_PATH_NOTE" ]]; then
    printf '  path_fix: %s\n' "$GPUUP_NVCC_PATH_NOTE"
  fi
  if (( GPUUP_IS_WSL )); then
    printf '  driver_action: skipped (WSL)\n'
  else
    printf '  driver_action: install\n'
  fi
  printf '  packages:\n'
  if (( GPUUP_IS_WSL )); then
    printf '    - %s\n' "$(gpuup_package_for_toolkit "$GPUUP_EFFECTIVE_CUDA")"
  else
    printf '    - %s\n' "$(gpuup_package_for_driver "$GPUUP_EFFECTIVE_DRIVER" "$GPUUP_MODULE_FLAVOR")"
    printf '    - %s\n' "$(gpuup_package_for_toolkit "$GPUUP_EFFECTIVE_CUDA")"
    local fabric
    fabric=$(gpuup_package_for_fabric "$GPUUP_EFFECTIVE_DRIVER" "$GPUUP_MODULE_FLAVOR") || true
    if [[ -n "$fabric" ]]; then
      printf '    - %s\n' "$fabric"
    fi
  fi
  printf '  apt_actions:\n'
  local key_url
  key_url=$(gpuup_cuda_keyring_url)
  printf '    - apt-get update\n'
  printf '    - apt-get install -y curl ca-certificates\n'
  printf '    - dpkg -i cuda-keyring_1.1-1_all.deb (from %s)\n' "$key_url"
  printf '    - apt-get update\n'
  if (( GPUUP_IS_WSL )); then
    printf '    - apt-get install -y %s\n' "$(gpuup_package_for_toolkit "$GPUUP_EFFECTIVE_CUDA")"
  else
    printf '    - apt-get install -y build-essential dkms linux-headers-%s pciutils\n' "$(uname -r)"
    printf '    - apt-get install -y %s\n' "$(gpuup_package_for_driver "$GPUUP_EFFECTIVE_DRIVER" "$GPUUP_MODULE_FLAVOR")"
    printf '    - apt-get install -y %s\n' "$(gpuup_package_for_toolkit "$GPUUP_EFFECTIVE_CUDA")"
    local fabric_cmd
    fabric_cmd=$(gpuup_package_for_fabric "$GPUUP_EFFECTIVE_DRIVER" "$GPUUP_MODULE_FLAVOR") || true
    if [[ -n "$fabric_cmd" ]]; then
      printf '    - apt-get install -y %s\n' "$fabric_cmd"
    fi
  fi
  printf '  steps:\n'
  if (( GPUUP_IS_WSL )); then
    printf '    - install cuda-keyring\n'
    printf '    - apt-get update\n'
    printf '    - install toolkit meta-package only\n'
    printf '    - warn user about Windows driver\n'
  else
    printf '    - install cuda-keyring\n'
    printf '    - apt-get update\n'
    printf '    - install prerequisites\n'
    printf '    - blacklist nouveau if needed\n'
    printf '    - install driver meta-package\n'
    printf '    - install toolkit meta-package\n'
    if (( GPUUP_NEEDS_FABRIC )); then
      printf '    - install and enable fabric manager\n'
    fi
    printf '    - ensure /etc/profile.d/cuda.sh exports paths\n'
    printf '    - verify nvcc and nvidia-smi\n'
  fi
}

gpuup_verify_only() {
  if (( GPUUP_ASSUME_VERIFY_SUCCESS )); then
    gpuup_log "Simulating verification success (GPUUP_ASSUME_VERIFY_SUCCESS=1)"
    exit 0
  fi
  if gpuup_short_circuit_success; then
    exit 0
  fi
  gpuup_err "verification failed: nvcc and/or nvidia-smi unavailable"
}

gpuup_main() {
  gpuup_parse_args "$@"
  gpuup_check_cuda_value "$GPUUP_REQUESTED_CUDA"
  gpuup_check_driver_value "$GPUUP_REQUESTED_DRIVER"

  gpuup_detect_os
  gpuup_detect_arch
  gpuup_detect_wsl
  gpuup_collect_gpus
  gpuup_detect_installed_versions
  if (( GPUUP_DRIVER_PENDING_REBOOT )); then
    local msg="${GPUUP_NVSMI_FAILURE_MESSAGE//$'\n'/ }"
    if [[ -n "$msg" ]]; then
      gpuup_warn "$msg"
    fi
    gpuup_err "Detected NVIDIA driver/library mismatch. Reboot to load the new driver, then rerun gpuup (--verify-only)."
  fi
  gpuup_fabric_pref_from_flag
  gpuup_gpu_classify
  gpuup_set_default_versions

  if (( GPUUP_INTERACTIVE )); then
    gpuup_interactive_flow
  fi

  if (( GPUUP_VERIFY_ONLY )); then
    gpuup_verify_only
  fi

  if (( GPUUP_UNINSTALL )); then
    gpuup_uninstall
    exit 0
  fi

  gpuup_choose_cuda_version
  gpuup_choose_driver_branch
  gpuup_verify_driver_cuda_matrix

  if (( GPUUP_PLAN_ONLY )); then
    gpuup_plan_report
    exit 0
  fi

  if (( ! GPUUP_FORCE_INSTALL )) && gpuup_short_circuit_success; then
    exit 0
  fi

  if (( GPUUP_DRY_RUN )); then
    gpuup_log "dry-run mode: commands will be echoed"
  fi

  gpuup_install_driver_toolkit
  gpuup_ensure_profile_exports
  gpuup_offer_shell_exports
  gpuup_verify_post || true

  if (( ! GPUUP_NO_REBOOT )) && (( GPUUP_DRIVER_MODIFIED )); then
    gpuup_log "Reboot recommended to activate NVIDIA kernel modules"
  fi

  gpuup_offer_uv
}

gpuup_main "$@"
