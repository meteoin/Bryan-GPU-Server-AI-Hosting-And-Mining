#!/usr/bin/env bash
# Repair runtime files and the controlpanel command on an already-installed host.
set -Eeuo pipefail

BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${BOOTSTRAP_DIR}/common.sh"
bryan_init_paths

if [[ -f "${BRYAN_INSTALLED_FILE}" ]]; then
  SRC_DIR="$(bryan_json_get "${BRYAN_INSTALLED_FILE}" src_dir)"
  LIB_DIR="$(bryan_json_get "${BRYAN_INSTALLED_FILE}" lib_dir)"
  REPO="$(bryan_json_get "${BRYAN_INSTALLED_FILE}" repo)"
  REF="$(bryan_json_get "${BRYAN_INSTALLED_FILE}" ref)"
  SRC_DIR="${SRC_DIR:-${BRYAN_SRC_DIR}}"
  LIB_DIR="${LIB_DIR:-${BRYAN_LIB_DIR}}"
  REPO="${REPO:-${BRYAN_DEFAULT_REPO}}"
  REF="${REF:-${BRYAN_DEFAULT_REF}}"
  BRYAN_SRC_DIR="${SRC_DIR}"
  BRYAN_LIB_DIR="${LIB_DIR}"
fi

bryan_log "Repairing Bryan GPU setup from ${BRYAN_SRC_DIR}"
if bryan_sync_src_clone "${BRYAN_SRC_DIR}" "${REPO:-${BRYAN_DEFAULT_REPO}}" "${REF:-${BRYAN_DEFAULT_REF}}"; then
  bryan_log "Clone reset to origin/${REF:-${BRYAN_DEFAULT_REF}}"
fi
bryan_repair_runtime "${BRYAN_SRC_DIR}" "${BRYAN_LIB_DIR}"
bryan_log "Repair complete. Open a new shell or run: source ~/.bashrc && controlpanel"
if [[ -f "${BRYAN_LIB_DIR}/terminal_miner_control.py" ]]; then
  bryan_log "Fallback: python3 ${BRYAN_LIB_DIR}/terminal_miner_control.py"
fi
