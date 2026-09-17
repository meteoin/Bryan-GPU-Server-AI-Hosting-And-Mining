#!/usr/bin/env bash
# Interactive installer. Selects 170HX host bootstrap vs miner-only.
set -Eeuo pipefail

BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${BOOTSTRAP_DIR}/common.sh"
bryan_init_paths

REPO_ROOT="$(cd "${BOOTSTRAP_DIR}/../.." && pwd)"
export BRYAN_REPO_ROOT="${REPO_ROOT}"
export BRYAN_YES="${BRYAN_YES:-0}"
INSTALL_PROFILE="${INSTALL_PROFILE:-}"
ENABLE_MINER_SERVICE="${ENABLE_MINER_SERVICE:-0}"
NO_AUTO_UPDATE="${NO_AUTO_UPDATE:-0}"
UNLOCK_PROFILE="${UNLOCK_PROFILE:-auto}"
READY_ARGS=()

usage() {
  cat <<'EOF'
Usage:
  install.sh [options]

Options:
  --profile miner-only|170hx-host  Skip the menu and use this profile
  --yes                            Non-interactive; use defaults and env values
  --no-auto-update                 Do not enable the update timer
  --enable-miner-service           Enable and start the miner watcher immediately
  --unlock-profile auto|8gb|10gb   Passed through to ready_170hx_host.sh
  --help                           Show this help

Any extra arguments are passed to scripts/ready_170hx_host.sh when the
170hx-host profile runs.

Environment:
  MACHINE_ID, PRL_WALLET, WORKER_NAME, POOL, POOL_PASSWORD
  VAST_API_KEY or HOST_API_KEY
  BRYAN_SETUP_REPO, BRYAN_SETUP_REF
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile)
        INSTALL_PROFILE="$2"
        shift 2
        ;;
      --yes|-y)
        BRYAN_YES=1
        export BRYAN_YES
        shift
        ;;
      --no-auto-update)
        NO_AUTO_UPDATE=1
        shift
        ;;
      --enable-miner-service)
        ENABLE_MINER_SERVICE=1
        shift
        ;;
      --unlock-profile)
        UNLOCK_PROFILE="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      --)
        shift
        READY_ARGS+=("$@")
        break
        ;;
      *)
        READY_ARGS+=("$1")
        shift
        ;;
    esac
  done
}

select_profile() {
  if [[ -z "${INSTALL_PROFILE}" && "${BRYAN_YES}" != "1" && ! -e /dev/tty ]]; then
    bryan_fail "no TTY available; rerun with --profile miner-only|170hx-host and --yes"
  fi
  # shellcheck source=detect_gpu.sh
  source "${BOOTSTRAP_DIR}/detect_gpu.sh"
  bryan_log "Detected GPUs: ${DETECTED_SUMMARY}"

  if [[ -n "${INSTALL_PROFILE}" ]]; then
    case "${INSTALL_PROFILE}" in
      miner-only|170hx-host) ;;
      *) bryan_fail "unknown --profile ${INSTALL_PROFILE}" ;;
    esac
  elif [[ "${BRYAN_YES}" == "1" ]]; then
    INSTALL_PROFILE="${RECOMMENDED_PROFILE}"
    [[ -n "${INSTALL_PROFILE}" ]] || bryan_fail "no NVIDIA GPU detected"
  else
    if [[ "${DETECTED_KIND}" == "none" ]]; then
      bryan_fail "no NVIDIA GPU detected; refusing to install"
    fi
    printf '\nDetected: %s\n\n' "${DETECTED_SUMMARY}" > /dev/tty
    if [[ "${DETECTED_KIND}" == "170hx" || "${DETECTED_KIND}" == "mixed" ]]; then
      cat > /dev/tty <<EOF
  1) 170HX Vast host + idle PRL mining  [recommended]
  2) Mining + terminal only
  3) Quit
EOF
      local choice
      choice="$(bryan_prompt "Select" "1")"
      case "${choice}" in
        1|"") INSTALL_PROFILE="170hx-host" ;;
        2) INSTALL_PROFILE="miner-only" ;;
        *) exit 0 ;;
      esac
    else
      cat > /dev/tty <<EOF
  1) Mining + terminal only  [recommended]
  2) Quit
EOF
      local choice
      choice="$(bryan_prompt "Select" "1")"
      case "${choice}" in
        1|"") INSTALL_PROFILE="miner-only" ;;
        *) exit 0 ;;
      esac
    fi
  fi

  if [[ "${INSTALL_PROFILE}" == "170hx-host" && "${DETECTED_KIND}" != "170hx" && "${DETECTED_KIND}" != "mixed" ]]; then
    bryan_fail "170hx-host profile requires a CMP 170HX GPU. Detected: ${DETECTED_SUMMARY}"
  fi
  if [[ -z "${INSTALL_PROFILE}" ]]; then
    bryan_fail "no install profile selected"
  fi
  export INSTALL_PROFILE ENABLE_MINER_SERVICE NO_AUTO_UPDATE
  bryan_log "Using profile ${INSTALL_PROFILE}"
}

ensure_src_mirror() {
  if [[ "$(cd "${REPO_ROOT}" && pwd)" == "$(mkdir -p "${BRYAN_SRC_DIR}" && cd "${BRYAN_SRC_DIR}" && pwd)" ]]; then
    return 0
  fi
  bryan_log "Mirroring repo into ${BRYAN_SRC_DIR}"
  mkdir -p "$(dirname "${BRYAN_SRC_DIR}")"
  if [[ -d "${BRYAN_SRC_DIR}/.git" ]]; then
    git -C "${BRYAN_SRC_DIR}" fetch --depth 1 origin "${BRYAN_SETUP_REF:-${BRYAN_DEFAULT_REF}}" || true
    return 0
  fi
  if [[ -d "${REPO_ROOT}/.git" ]]; then
    git clone --depth 1 "${REPO_ROOT}" "${BRYAN_SRC_DIR}"
    git -C "${BRYAN_SRC_DIR}" remote set-url origin "${BRYAN_SETUP_REPO:-${BRYAN_DEFAULT_REPO}}" || true
    return 0
  fi
  mkdir -p "${BRYAN_SRC_DIR}"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --exclude '.git' "${REPO_ROOT}/" "${BRYAN_SRC_DIR}/"
  else
    cp -a "${REPO_ROOT}/." "${BRYAN_SRC_DIR}/"
  fi
}

run_170hx_bootstrap() {
  local script="${REPO_ROOT}/scripts/ready_170hx_host.sh"
  [[ -f "${script}" ]] || bryan_fail "missing ${script}"
  chmod +x "${script}"
  bryan_log "Running 170HX host bootstrap"
  set +e
  "${script}" --profile "${UNLOCK_PROFILE}" "${READY_ARGS[@]}"
  local rc=$?
  set -e
  case "${rc}" in
    0)
      bryan_log "170HX bootstrap completed"
      ;;
    20)
      bryan_log "Reboot required. Rerun the same install command after reboot."
      exit 20
      ;;
    30)
      bryan_log "Cold power-off required. Power on, then rerun the same install command."
      exit 30
      ;;
    40|41)
      bryan_log "170HX bootstrap paused for a manual step. Rerun the same install command when that step is done."
      exit "${rc}"
      ;;
    *)
      bryan_fail "ready_170hx_host.sh exited ${rc}"
      ;;
  esac
}

parse_args "$@"
select_profile
ensure_src_mirror

if [[ "${INSTALL_PROFILE}" == "170hx-host" ]]; then
  run_170hx_bootstrap
fi

chmod +x "${BOOTSTRAP_DIR}/install_miner.sh"
"${BOOTSTRAP_DIR}/install_miner.sh"
bryan_log "Install finished for profile ${INSTALL_PROFILE}"
