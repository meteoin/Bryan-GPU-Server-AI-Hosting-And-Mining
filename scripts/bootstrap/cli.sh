#!/usr/bin/env bash
set -Eeuo pipefail

BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${BOOTSTRAP_DIR}/common.sh"
bryan_init_paths

usage() {
  cat <<'EOF'
Usage:
  bryan-gpu-setup <command>

Commands:
  install [options]   Run the host installer
  update --check      Fetch repo update info without applying
  update --apply      Fetch and apply changed components
  update --status     Show installed component versions
  gpu                 Print GPU detection summary
  controlpanel        Open the terminal miner control panel
  help                Show this help
EOF
}

COMMAND="${1:-help}"
if [[ $# -gt 0 ]]; then
  shift
fi

case "${COMMAND}" in
  install)
    exec bash "${BOOTSTRAP_DIR}/install.sh" "$@"
    ;;
  update)
    exec bash "${BOOTSTRAP_DIR}/update.sh" "$@"
    ;;
  gpu|detect)
    exec bash "${BOOTSTRAP_DIR}/detect_gpu.sh" --print
    ;;
  controlpanel|panel)
    exec bash "${BOOTSTRAP_DIR}/../controlpanel" "$@"
    ;;
  status)
    exec bash "${BOOTSTRAP_DIR}/update.sh" --status
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
