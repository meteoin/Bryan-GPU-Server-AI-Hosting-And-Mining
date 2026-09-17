#!/usr/bin/env bash
# Install mining watcher, terminal app, SRBMiner, env, and systemd units.
set -Eeuo pipefail

BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${BOOTSTRAP_DIR}/common.sh"
bryan_init_paths

REPO_ROOT="${BRYAN_REPO_ROOT:-$(cd "${BOOTSTRAP_DIR}/../.." && pwd)}"
MANIFEST_FILE="${REPO_ROOT}/manifest.json"
INSTALL_PROFILE="${INSTALL_PROFILE:-miner-only}"
ENABLE_MINER_SERVICE="${ENABLE_MINER_SERVICE:-0}"
NO_AUTO_UPDATE="${NO_AUTO_UPDATE:-0}"
INSTALL_SUDOERS="${INSTALL_SUDOERS:-ask}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || bryan_fail "missing required command: $1"
}

install_packages_if_needed() {
  local packages=()
  command -v python3 >/dev/null 2>&1 || packages+=(python3)
  command -v git >/dev/null 2>&1 || packages+=(git)
  command -v curl >/dev/null 2>&1 || packages+=(curl)
  command -v pipx >/dev/null 2>&1 || packages+=(pipx)
  command -v tar >/dev/null 2>&1 || packages+=(tar)
  if [[ "${#packages[@]}" -eq 0 ]]; then
    return 0
  fi
  bryan_log "Installing packages: ${packages[*]}"
  if command -v apt-get >/dev/null 2>&1; then
    bryan_run_sudo apt-get update
    bryan_run_sudo apt-get install -y "${packages[@]}"
  else
    bryan_fail "need ${packages[*]} installed, and apt-get is not available"
  fi
}

copy_component_files() {
  local component="$1"
  bryan_python - "${MANIFEST_FILE}" "${REPO_ROOT}" "${BRYAN_LIB_DIR}" "${component}" <<'PY'
import json
import os
import shutil
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text())
repo_root = Path(sys.argv[2])
lib_dir = Path(sys.argv[3])
component = sys.argv[4]
spec = manifest["components"][component]
lib_dir.mkdir(parents=True, exist_ok=True)
for rel in spec.get("files", []):
    src = repo_root / rel
    dest = lib_dir / Path(rel).name
    if not src.exists():
        raise SystemExit(f"missing source file: {src}")
    tmp = dest.with_suffix(dest.suffix + ".tmp")
    shutil.copy2(src, tmp)
    if os.access(src, os.X_OK) or src.suffix == ".sh":
        tmp.chmod(tmp.stat().st_mode | 0o111)
    tmp.replace(dest)
    print(dest)
PY
}

ensure_srbminer() {
  if [[ -x "${BRYAN_SRBMINER_BIN}" ]]; then
    bryan_log "SRBMiner already present at ${BRYAN_SRBMINER_BIN}"
    return 0
  fi
  require_cmd curl
  require_cmd tar
  mkdir -p "${BRYAN_SRBMINER_DIR}"
  local archive="${BRYAN_SRBMINER_DIR}/srbminer-linux.tar.gz"
  bryan_log "Downloading SRBMiner ${BRYAN_SRBMINER_VERSION}"
  bryan_curl -o "${archive}" "${BRYAN_SRBMINER_URL}"
  tar -xzf "${archive}" -C "${BRYAN_SRBMINER_DIR}"
  local found
  found="$(find "${BRYAN_SRBMINER_DIR}" -type f -name 'SRBMiner-MULTI' | head -n 1 || true)"
  [[ -n "${found}" ]] || bryan_fail "SRBMiner-MULTI not found after extract"
  cp "${found}" "${BRYAN_SRBMINER_BIN}"
  chmod +x "${BRYAN_SRBMINER_BIN}"
}

upsert_env_value() {
  local key="$1"
  local value="$2"
  local file="$3"
  bryan_python - "${file}" "${key}" "${value}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
lines = path.read_text().splitlines() if path.exists() else []
updated = False
out = []
for line in lines:
    stripped = line.strip()
    if stripped and not stripped.startswith("#") and stripped.split("=", 1)[0] == key:
        out.append(f"{key}={value}")
        updated = True
    else:
        out.append(line)
if not updated:
    out.append(f"{key}={value}")
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text("\n".join(out) + "\n")
PY
}

read_env_value() {
  local key="$1"
  local file="$2"
  awk -F= -v key="${key}" '$1==key {print substr($0, index($0, "=")+1); exit}' "${file}" 2>/dev/null || true
}

write_env_file() {
  local example="${REPO_ROOT}/config/vast-prl-host-miner.env.example"
  if [[ ! -f "${BRYAN_ENV_FILE}" ]]; then
    cp "${example}" "${BRYAN_ENV_FILE}"
    chmod 600 "${BRYAN_ENV_FILE}"
  fi

  local machine_id wallet worker pool password
  machine_id="$(read_env_value MACHINE_ID "${BRYAN_ENV_FILE}")"
  wallet="$(read_env_value PRL_WALLET "${BRYAN_ENV_FILE}")"
  worker="$(read_env_value WORKER_NAME "${BRYAN_ENV_FILE}")"
  pool="$(read_env_value POOL "${BRYAN_ENV_FILE}")"
  password="$(read_env_value POOL_PASSWORD "${BRYAN_ENV_FILE}")"

  machine_id="${MACHINE_ID:-${machine_id}}"
  wallet="${PRL_WALLET:-${wallet}}"
  worker="${WORKER_NAME:-${worker:-$(hostname -s 2>/dev/null || hostname)}}"
  pool="${POOL:-${pool:-pearl-us-west.luckypool.io:3360}}"
  password="${POOL_PASSWORD:-${password:-x}}"

  if [[ "${BRYAN_YES}" != "1" ]]; then
    machine_id="$(bryan_prompt "Vast machine ID" "${machine_id}")"
    wallet="$(bryan_prompt "PRL wallet" "${wallet}")"
    worker="$(bryan_prompt "Worker name" "${worker}")"
    pool="$(bryan_prompt "Pool host:port" "${pool}")"
    password="$(bryan_prompt "Pool password" "${password}")"
  fi

  [[ -n "${machine_id}" ]] || bryan_fail "MACHINE_ID is required"
  [[ -n "${wallet}" ]] || bryan_fail "PRL_WALLET is required"

  upsert_env_value MACHINE_ID "${machine_id}" "${BRYAN_ENV_FILE}"
  upsert_env_value PRL_WALLET "${wallet}" "${BRYAN_ENV_FILE}"
  upsert_env_value WORKER_NAME "${worker}" "${BRYAN_ENV_FILE}"
  upsert_env_value POOL "${pool}" "${BRYAN_ENV_FILE}"
  upsert_env_value POOL_PASSWORD "${password}" "${BRYAN_ENV_FILE}"
  upsert_env_value MINER_BIN "${BRYAN_SRBMINER_BIN}" "${BRYAN_ENV_FILE}"
  bryan_log "Wrote miner env file ${BRYAN_ENV_FILE}"
}

maybe_set_vast_api_key() {
  local key="${VAST_API_KEY:-${HOST_API_KEY:-}}"
  if [[ -z "${key}" && "${BRYAN_YES}" != "1" ]]; then
    key="$(bryan_prompt "Vast API key (blank to skip)" "")"
  fi
  if [[ -z "${key}" ]]; then
    bryan_log "Skipping vastai API key setup"
    return 0
  fi
  if ! command -v vastai >/dev/null 2>&1 && [[ ! -x "${HOME}/.local/bin/vastai" ]]; then
    if command -v pipx >/dev/null 2>&1; then
      pipx install vastai || true
      pipx ensurepath || true
    fi
  fi
  export PATH="${HOME}/.local/bin:${PATH}"
  if command -v vastai >/dev/null 2>&1; then
    vastai set api-key "${key}"
    bryan_log "Configured vastai CLI API key"
  else
    bryan_log "vastai CLI not available; set the API key later with: vastai set api-key"
  fi
}

install_sudoers_rule() {
  local nvidia_smi
  nvidia_smi="$(command -v nvidia-smi || true)"
  [[ -n "${nvidia_smi}" ]] || {
    bryan_log "nvidia-smi not found; skipping sudoers drop-in"
    return 0
  }
  local do_install=0
  if [[ "${INSTALL_SUDOERS}" == "1" ]]; then
    do_install=1
  elif [[ "${INSTALL_SUDOERS}" == "ask" && "${BRYAN_YES}" != "1" ]]; then
    if bryan_confirm "Install passwordless sudoers rule for ${nvidia_smi}?" "y"; then
      do_install=1
    fi
  fi
  if [[ "${do_install}" != "1" ]]; then
    return 0
  fi
  local dropin="/etc/sudoers.d/${BRYAN_USER}-nvidia-smi"
  printf '%s ALL=(root) NOPASSWD: %s\n' "${BRYAN_USER}" "${nvidia_smi}" | bryan_run_sudo tee "${dropin}" >/dev/null
  bryan_run_sudo chmod 440 "${dropin}"
  bryan_log "Installed sudoers drop-in ${dropin}"
}

install_miner_unit() {
  local rendered="${BRYAN_STATE_DIR}/vast-prl-host-miner.service"
  bryan_render_template "${REPO_ROOT}/systemd/vast-prl-host-miner.service.in" "${rendered}"
  if [[ "$(id -u)" -eq 0 ]] || bryan_can_sudo || sudo -n true >/dev/null 2>&1; then
    bryan_run_sudo cp "${rendered}" "/etc/systemd/system/${BRYAN_MINER_SERVICE}"
    bryan_run_sudo systemctl daemon-reload
    if [[ "${ENABLE_MINER_SERVICE}" == "1" ]]; then
      bryan_run_sudo systemctl enable --now "${BRYAN_MINER_SERVICE}"
      bryan_log "Enabled ${BRYAN_MINER_SERVICE}"
    else
      bryan_run_sudo systemctl enable "${BRYAN_MINER_SERVICE}"
      bryan_log "Installed ${BRYAN_MINER_SERVICE}; start later with: sudo systemctl start ${BRYAN_MINER_SERVICE}"
    fi
  else
    mkdir -p "${HOME}/.config/systemd/user"
    cp "${rendered}" "${HOME}/.config/systemd/user/${BRYAN_MINER_SERVICE}"
    systemctl --user daemon-reload
    bryan_log "Installed user unit ${BRYAN_MINER_SERVICE}; start with: systemctl --user start ${BRYAN_MINER_SERVICE}"
  fi
}

install_update_timer() {
  if [[ "${NO_AUTO_UPDATE}" == "1" ]]; then
    bryan_log "Skipping update timer (--no-auto-update)"
    return 0
  fi
  local rendered="${BRYAN_STATE_DIR}/bryan-gpu-setup-update.service"
  bryan_render_template "${REPO_ROOT}/systemd/bryan-gpu-setup-update.service.in" "${rendered}"
  if [[ "$(id -u)" -eq 0 ]] || bryan_can_sudo || sudo -n true >/dev/null 2>&1; then
    bryan_run_sudo cp "${rendered}" "/etc/systemd/system/${BRYAN_UPDATE_SERVICE}"
    bryan_run_sudo cp "${REPO_ROOT}/systemd/bryan-gpu-setup-update.timer" "/etc/systemd/system/${BRYAN_UPDATE_TIMER}"
    bryan_run_sudo systemctl daemon-reload
    bryan_run_sudo systemctl enable --now "${BRYAN_UPDATE_TIMER}"
    bryan_log "Enabled ${BRYAN_UPDATE_TIMER} to fetch repo updates every 6 hours"
  else
    mkdir -p "${HOME}/.config/systemd/user"
    cp "${rendered}" "${HOME}/.config/systemd/user/${BRYAN_UPDATE_SERVICE}"
    cp "${REPO_ROOT}/systemd/bryan-gpu-setup-update.timer" "${HOME}/.config/systemd/user/${BRYAN_UPDATE_TIMER}"
    systemctl --user daemon-reload
    systemctl --user enable --now "${BRYAN_UPDATE_TIMER}"
    bryan_log "Enabled user update timer ${BRYAN_UPDATE_TIMER}"
  fi
}

install_cli_wrapper() {
  bryan_install_cli_from_tree "${REPO_ROOT}"
  bryan_log "Installed CLI ${BRYAN_BIN_DIR}/bryan-gpu-setup"
  bryan_log "Installed controlpanel ${BRYAN_BIN_DIR}/controlpanel"
}

write_installed_state() {
  local repo="${BRYAN_SETUP_REPO:-${BRYAN_DEFAULT_REPO}}"
  local ref="${BRYAN_SETUP_REF:-${BRYAN_DEFAULT_REF}}"
  bryan_python - "${MANIFEST_FILE}" "${BRYAN_INSTALLED_FILE}" "${INSTALL_PROFILE}" "${repo}" "${ref}" "${BRYAN_SRC_DIR}" "${BRYAN_LIB_DIR}" "${NO_AUTO_UPDATE}" <<'PY'
import json
import sys
import time
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text())
out_path = Path(sys.argv[2])
profile = sys.argv[3]
repo = sys.argv[4]
ref = sys.argv[5]
src_dir = sys.argv[6]
lib_dir = sys.argv[7]
no_auto = sys.argv[8] == "1"
components = {}
for name, spec in manifest.get("components", {}).items():
    profiles = spec.get("profiles", [])
    if profile in profiles:
        components[name] = spec.get("version", "")
payload = {
    "profile": profile,
    "release": manifest.get("release", ""),
    "channel": manifest.get("channel", "stable"),
    "repo": repo,
    "ref": ref,
    "src_dir": src_dir,
    "lib_dir": lib_dir,
    "update_auto": not no_auto,
    "update_srbminer": False,
    "installed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "components": components,
    "pending_restart": [],
}
out_path.parent.mkdir(parents=True, exist_ok=True)
tmp = out_path.with_suffix(out_path.suffix + ".tmp")
tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
tmp.replace(out_path)
PY
}

install_packages_if_needed
copy_component_files miner-watcher
copy_component_files terminal-app
copy_component_files gpu-tuning
ensure_srbminer
write_env_file
maybe_set_vast_api_key
install_sudoers_rule
install_cli_wrapper
install_miner_unit
install_update_timer
write_installed_state
bryan_log "Mining stack installed for profile ${INSTALL_PROFILE}"
printf '\nNext:\n'
printf '  controlpanel\n'
printf '  bryan-gpu-setup update --status\n'
printf '  sudo systemctl start %s\n' "${BRYAN_MINER_SERVICE}"
