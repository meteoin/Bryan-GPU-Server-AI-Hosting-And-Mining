#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="0.1.0"
STATE_DIR_DEFAULT="/var/tmp/170hx-ready"
NVIDIA_DRIVER_VERSION="610.43.02"
PROFILE_MODE="auto"
DATA_DISK=""
VAST_INSTALLER_CMD=""
VAST_INSTALLER_CMD_FILE=""
HOST_API_KEY=""
SKIP_UNLOCK=0
SKIP_STORAGE=0
SKIP_VAST_HOST=0
CONFIRM_SSH_KEY_AUTH=0
RUN_VAST_INSTALLER=0
AUTO_REBOOT=0
AUTO_POWEROFF=0
DOCKER_MOUNT="/var/lib/docker"
POLL_HOSTNAME="$(hostname -s 2>/dev/null || hostname)"
STATE_DIR="${STATE_DIR_DEFAULT}/${POLL_HOSTNAME}"
STATE_FILE=""
LOG_DIR=""
SUMMARY_FILE=""
LAST_LOGFILE=""
CURRENT_STEP=""
CURRENT_CMD=""
RUN_LOG=""

usage() {
  cat <<'EOF'
Usage:
  ready_170hx_host.sh [options]

Options:
  --profile auto|8gb|10gb      CMP unlock profile. Default: auto
  --data-disk /dev/nvme0n1     Optional disk to migrate Docker data onto as XFS
  --vast-installer-cmd "..."   Vast-generated one-line host installer command
  --vast-installer-cmd-file F  File containing the Vast-generated installer command
  --host-api-key KEY           Optional Vast host API key for `vastai set api-key`
  --auto-reboot                Reboot automatically after driver install if needed
  --auto-poweroff              Power off automatically after cmpunlocker install if needed
  --skip-unlock                Skip cmpunlocker install/verify flow
  --skip-storage               Skip optional Docker data-disk migration
  --skip-vast-host             Skip Vast host installer/service verification
  --confirm-ssh-key-auth       Confirm SSH key login was tested; script may disable password auth
  --run-vast-installer         Actually run the Vast installer command from this script
  --state-dir DIR              Override state/log directory
  --help                       Show this help

Behavior:
  - Stops immediately on failure
  - Writes per-step logs and a failure summary
  - Skips steps that are already satisfied
  - Persists state across reruns, reboot, and cold power-off
  - Pauses for SSH key handoff before disabling password authentication
  - Stops at the Vast host enrollment handoff unless --run-vast-installer is explicitly used
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile)
        PROFILE_MODE="$2"
        shift 2
        ;;
      --data-disk)
        DATA_DISK="$2"
        shift 2
        ;;
      --vast-installer-cmd)
        VAST_INSTALLER_CMD="$2"
        shift 2
        ;;
      --vast-installer-cmd-file)
        VAST_INSTALLER_CMD_FILE="$2"
        shift 2
        ;;
      --host-api-key)
        HOST_API_KEY="$2"
        shift 2
        ;;
      --auto-reboot)
        AUTO_REBOOT=1
        shift
        ;;
      --auto-poweroff)
        AUTO_POWEROFF=1
        shift
        ;;
      --skip-unlock)
        SKIP_UNLOCK=1
        shift
        ;;
      --skip-storage)
        SKIP_STORAGE=1
        shift
        ;;
      --skip-vast-host)
        SKIP_VAST_HOST=1
        shift
        ;;
      --confirm-ssh-key-auth)
        CONFIRM_SSH_KEY_AUTH=1
        shift
        ;;
      --run-vast-installer)
        RUN_VAST_INSTALLER=1
        shift
        ;;
      --state-dir)
        STATE_DIR="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done
}

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

log() {
  local line
  line="[$(timestamp)] $*"
  if [[ -n "${RUN_LOG}" ]]; then
    printf '%s\n' "${line}" | tee -a "${RUN_LOG}"
  else
    printf '%s\n' "${line}"
  fi
}

prepare_state() {
  mkdir -p "${STATE_DIR}/logs"
  STATE_FILE="${STATE_DIR}/state.env"
  LOG_DIR="${STATE_DIR}/logs"
  SUMMARY_FILE="${STATE_DIR}/last_failure.txt"
  RUN_LOG="${STATE_DIR}/run.log"
  touch "${STATE_FILE}"
  touch "${RUN_LOG}"
  if [[ -s "${STATE_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${STATE_FILE}"
  fi
  log "===== ready_170hx_host.sh ${SCRIPT_VERSION} starting ====="
  log "State directory: ${STATE_DIR}"
}

save_state_kv() {
  local key="$1"
  local value="$2"
  python3 - <<PY
from pathlib import Path
path = Path(${STATE_FILE@Q})
lines = []
if path.exists():
    lines = path.read_text().splitlines()
key = ${key@Q}
value = ${value@Q}
updated = False
for i, line in enumerate(lines):
    if line.startswith(key + "="):
        lines[i] = f"{key}={value}"
        updated = True
        break
if not updated:
    lines.append(f"{key}={value}")
path.write_text("\n".join(lines) + ("\n" if lines else ""))
PY
}

mark_step_done() {
  local step="$1"
  save_state_kv "STEP_${step}" "done"
}

step_done() {
  local step="$1"
  local var="STEP_${step:-}"
  [[ "${!var:-}" == "done" ]]
}

write_failure_summary() {
  local exit_code="$1"
  {
    echo "step=${CURRENT_STEP}"
    echo "command=${CURRENT_CMD}"
    echo "exit_code=${exit_code}"
    echo "log=${LAST_LOGFILE}"
    echo
    echo "Last log lines:"
    if [[ -n "${LAST_LOGFILE}" && -f "${LAST_LOGFILE}" ]]; then
      tail -n 40 "${LAST_LOGFILE}"
    else
      echo "(no log available)"
    fi
  } > "${SUMMARY_FILE}"
}

on_error() {
  local exit_code=$?
  write_failure_summary "${exit_code}"
  log "FAILED at step '${CURRENT_STEP}'"
  log "Command: ${CURRENT_CMD}"
  log "Exit code: ${exit_code}"
  log "Failure summary: ${SUMMARY_FILE}"
  exit "${exit_code}"
}

trap on_error ERR

run_cmd() {
  local step="$1"
  local command="$2"
  local slug
  slug="$(printf '%s' "${step}" | tr ' ' '_' | tr -cd '[:alnum:]_')"
  LAST_LOGFILE="${LOG_DIR}/$(date +%Y%m%d_%H%M%S)_${slug}.log"
  CURRENT_STEP="${step}"
  CURRENT_CMD="${command}"
  log "STEP: ${step}"
  log "CMD: ${command}"
  bash -lc "${command}" 2>&1 | tee "${LAST_LOGFILE}"
}

skip_step() {
  local step="$1"
  local reason="$2"
  log "SKIP: ${step} (${reason})"
}

require_root_tools() {
  command -v sudo >/dev/null 2>&1 || {
    echo "sudo is required" >&2
    exit 1
  }
}

prechecks() {
  local step="prechecks"
  if step_done "${step}"; then
    skip_step "${step}" "already recorded"
    return
  fi

  local arch pretty secure gpu_list
  arch="$(uname -m)"
  pretty="$(source /etc/os-release && echo "${PRETTY_NAME}")"
  secure="$(mokutil --sb-state 2>/dev/null || true)"
  gpu_list="$(lspci -nn | grep -Ei 'NVIDIA|3D|VGA' || true)"

  [[ "${arch}" == "x86_64" ]] || {
    CURRENT_STEP="${step}"
    CURRENT_CMD="uname -m"
    echo "Expected x86_64, got ${arch}" >&2
    return 1
  }
  [[ "${pretty}" == Ubuntu\ 24.04* ]] || {
    CURRENT_STEP="${step}"
    CURRENT_CMD="source /etc/os-release && echo \$PRETTY_NAME"
    echo "Expected Ubuntu 24.04.x, got ${pretty}" >&2
    return 1
  }
  [[ "${secure}" == *"disabled"* || "${secure}" == *"Setup Mode"* ]] || {
    CURRENT_STEP="${step}"
    CURRENT_CMD="mokutil --sb-state"
    echo "Secure Boot must be disabled. Output: ${secure}" >&2
    return 1
  }
  [[ "${gpu_list}" == *"CMP 170HX"* ]] || {
    CURRENT_STEP="${step}"
    CURRENT_CMD="lspci -nn | grep -Ei 'NVIDIA|3D|VGA'"
    echo "CMP 170HX GPU not detected" >&2
    return 1
  }

  {
    echo "arch=${arch}"
    echo "os=${pretty}"
    echo "secure_boot=${secure}"
    echo "${gpu_list}"
  } > "${LOG_DIR}/prechecks_snapshot.log"
  mark_step_done "${step}"
}

packages_installed() {
  dpkg -s "$@" >/dev/null 2>&1
}

ensure_base_packages() {
  local step="base_packages"
  local packages=(python3 python3-pip git curl patch build-essential mokutil "linux-headers-$(uname -r)" pipx docker.io xfsprogs rsync parted)
  if packages_installed "${packages[@]}"; then
    skip_step "${step}" "packages already installed"
    mark_step_done "${step}"
    return
  fi

  run_cmd "${step}_apt_update" "sudo apt update"
  run_cmd "${step}" "sudo apt install -y ${packages[*]}"
  run_cmd "${step}_pipx_ensurepath" "pipx ensurepath"
  mark_step_done "${step}"
}

ensure_docker() {
  local step="docker"
  if systemctl is-active --quiet docker; then
    skip_step "${step}" "docker already active"
    mark_step_done "${step}"
    return
  fi

  run_cmd "${step}" "sudo systemctl enable --now docker"
  run_cmd "${step}_status" "sudo systemctl status docker --no-pager"
  mark_step_done "${step}"
}

ensure_nvidia_repo() {
  local step="nvidia_repo"
  if [[ -f /etc/apt/sources.list.d/cuda-ubuntu2404-x86_64.list ]]; then
    skip_step "${step}" "CUDA repo already present"
    mark_step_done "${step}"
    return
  fi

  run_cmd "${step}_download" "cd /tmp && wget -q https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb"
  run_cmd "${step}_install" "cd /tmp && sudo dpkg -i cuda-keyring_1.1-1_all.deb"
  run_cmd "${step}_apt_update" "sudo apt update"
  mark_step_done "${step}"
}

nvidia_version_available() {
  apt_cache_driver_version >/dev/null
}

apt_cache_driver_version() {
  apt-cache madison nvidia-open | awk '$3 ~ /^'"${NVIDIA_DRIVER_VERSION//./\\.}"'([.-]|$)/ {print $3; exit}'
}

ensure_pinned_driver() {
  local step="pinned_driver"
  local installed_version=""
  local package_version=""
  if command -v modinfo >/dev/null 2>&1; then
    installed_version="$(modinfo -F version nvidia 2>/dev/null || true)"
  fi

  if [[ "${installed_version}" == "${NVIDIA_DRIVER_VERSION}" ]]; then
    skip_step "${step}" "driver already loaded at ${NVIDIA_DRIVER_VERSION}"
    mark_step_done "${step}"
    return
  fi

  package_version="$(apt_cache_driver_version || true)"
  if [[ -z "${package_version}" ]]; then
    CURRENT_STEP="${step}"
    CURRENT_CMD="apt-cache madison nvidia-open"
    apt-cache madison nvidia-open > "${LOG_DIR}/nvidia_open_madison.log" 2>&1 || true
    echo "Required nvidia-open ${NVIDIA_DRIVER_VERSION} package is not available. See ${LOG_DIR}/nvidia_open_madison.log" >&2
    return 1
  fi

  run_cmd "${step}_pin" "sudo apt install -y nvidia-driver-pinning-${NVIDIA_DRIVER_VERSION}"
  run_cmd "${step}_install" "sudo apt install -y nvidia-open=${package_version}"
  save_state_kv "NEEDS_DRIVER_REBOOT" "1"
  mark_step_done "${step}"
  request_reboot "${step}" "Driver install completed. Reboot required before continuing."
}

verify_driver() {
  local step="verify_driver"
  local version name_mem
  version="$(modinfo -F version nvidia 2>/dev/null || true)"
  name_mem="$(nvidia-smi --query-gpu=driver_version,name,memory.total --format=csv 2>/dev/null || true)"

  if [[ "${version}" == "${NVIDIA_DRIVER_VERSION}" && "${name_mem}" == *"CMP 170HX"* ]]; then
    {
      echo "${name_mem}"
      echo "modinfo=${version}"
    } > "${LOG_DIR}/verify_driver_snapshot.log"
    save_state_kv "NEEDS_DRIVER_REBOOT" "0"
    save_state_kv "PENDING_ACTION" "none"
    mark_step_done "${step}"
    return
  fi

  run_cmd "${step}_nvidia_smi" "nvidia-smi --query-gpu=driver_version,name,memory.total --format=csv"
  run_cmd "${step}_modinfo" "modinfo -F version nvidia"
  save_state_kv "NEEDS_DRIVER_REBOOT" "0"
  save_state_kv "PENDING_ACTION" "none"
  mark_step_done "${step}"
}

ensure_vast_cli() {
  local step="vast_cli"
  if command -v vastai >/dev/null 2>&1 || [[ -x "${HOME}/.local/bin/vastai" ]]; then
    skip_step "${step}" "vastai already installed"
    mark_step_done "${step}"
    return
  fi

  run_cmd "${step}_install" "export PATH=\"\$HOME/.local/bin:\$PATH\" && pipx install vastai"
  run_cmd "${step}_symlink" "if [[ -x \"\$HOME/.local/bin/vastai\" ]]; then sudo ln -sf \"\$HOME/.local/bin/vastai\" /usr/local/bin/vastai; fi"
  run_cmd "${step}_verify" "export PATH=\"\$HOME/.local/bin:\$PATH\" && vastai --help"
  mark_step_done "${step}"
}

detect_unlock_profile() {
  if [[ "${PROFILE_MODE}" == "8gb" || "${PROFILE_MODE}" == "10gb" ]]; then
    printf '%s' "${PROFILE_MODE}"
    return
  fi

  local memory
  memory="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -n1 | tr -d '[:space:]')"
  if [[ "${memory}" =~ ^[0-9]+$ ]]; then
    if (( memory >= 9500 && memory <= 10500 )); then
      printf '10gb'
      return
    fi
    if (( memory >= 7800 && memory <= 8600 )); then
      printf '8gb'
      return
    fi
  fi

  CURRENT_STEP="detect_unlock_profile"
  CURRENT_CMD="nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits"
  echo "Unable to auto-detect unlock profile from memory.total=${memory}" >&2
  return 1
}

ensure_cmpunlocker_repo() {
  local step="cmpunlocker_repo"
  if [[ -x "${HOME}/cmpunlocker/install.sh" && -x "${HOME}/cmpunlocker/verify.sh" ]]; then
    skip_step "${step}" "cmpunlocker repo already present"
    mark_step_done "${step}"
    return
  fi

  if [[ -d "${HOME}/cmpunlocker/.git" ]]; then
    run_cmd "${step}_refresh" "cd \"${HOME}/cmpunlocker\" && git fetch --all --tags && git reset --hard origin/HEAD"
  else
    run_cmd "${step}" "cd \"${HOME}\" && git clone https://github.com/amoghmunikote/cmpunlocker.git"
  fi
  mark_step_done "${step}"
}

verify_unlock_status() {
  sudo "${HOME}/cmpunlocker/verify.sh" >/dev/null 2>&1
}

request_reboot() {
  local step="$1"
  local reason="$2"
  CURRENT_STEP="${step}"
  CURRENT_CMD="sudo reboot"
  log "${reason}"
  save_state_kv "PENDING_ACTION" "reboot"
  if [[ "${AUTO_REBOOT}" == "1" ]]; then
    log "Auto reboot enabled. Rebooting now."
    sudo reboot || true
    exit 0
  fi
  log "Rerun this script after reboot. State is saved in ${STATE_DIR}."
  exit 20
}

request_poweroff() {
  local step="$1"
  local reason="$2"
  CURRENT_STEP="${step}"
  CURRENT_CMD="sudo shutdown -h now"
  log "${reason}"
  save_state_kv "PENDING_ACTION" "poweroff"
  if [[ "${AUTO_POWEROFF}" == "1" ]]; then
    log "Auto power-off enabled. Shutting down now."
    sudo shutdown -h now || true
    exit 0
  fi
  log "Power the machine back on and rerun this script."
  exit 30
}

ssh_password_disabled() {
  sudo sshd -T 2>/dev/null | grep -q '^passwordauthentication no$'
}

print_ssh_key_prompt() {
  local host_label
  host_label="${POLL_HOSTNAME:-170hx-host}"
  log "SSH key-only access must be verified before Vast host install."
  log "Run this on your local machine to generate a key with an empty passphrase:"
  log "  ssh-keygen -t ed25519 -C '${host_label}' -f ~/.ssh/${host_label}_ed25519 -N ''"
  log "Print the public key so you can copy it:"
  log "  cat ~/.ssh/${host_label}_ed25519.pub"
  log "Put that public key on the server in:"
  log "  /home/${USER}/.ssh/authorized_keys"
  log "Server-side commands:"
  log "  mkdir -p ~/.ssh && chmod 700 ~/.ssh"
  log "  printf '%s\n' '<PASTE_PUBLIC_KEY_HERE>' >> ~/.ssh/authorized_keys"
  log "  chmod 600 ~/.ssh/authorized_keys"
  log "Test from your local machine:"
  log "  ssh -i ~/.ssh/${host_label}_ed25519 ${USER}@<SERVER_IP>"
  log "After key login works, rerun this script with --confirm-ssh-key-auth."
}

ensure_ssh_key_handoff() {
  local step="ssh_key_handoff"
  if ssh_password_disabled; then
    skip_step "${step}" "password authentication already disabled"
    mark_step_done "${step}"
    return
  fi

  if [[ "${CONFIRM_SSH_KEY_AUTH}" != "1" ]]; then
    CURRENT_STEP="${step}"
    CURRENT_CMD="Manual SSH key setup"
    print_ssh_key_prompt
    save_state_kv "PENDING_ACTION" "ssh_key_handoff"
    exit 41
  fi

  mark_step_done "${step}"
}

ensure_ssh_password_deactivated() {
  local step="ssh_password_deactivation"
  if ssh_password_disabled; then
    skip_step "${step}" "password authentication already disabled"
    mark_step_done "${step}"
    return
  fi

  run_cmd "${step}_cloud_init" "echo 'PasswordAuthentication no' | sudo tee /etc/ssh/sshd_config.d/50-cloud-init.conf"
  run_cmd "${step}_vast_override" "printf '%s\n' 'PasswordAuthentication no' 'PubkeyAuthentication yes' 'KbdInteractiveAuthentication no' | sudo tee /etc/ssh/sshd_config.d/99-vast.conf"
  run_cmd "${step}_main_file" "sudo sed -ri 's/^[[:space:]]*#?[[:space:]]*PasswordAuthentication[[:space:]]+.*/PasswordAuthentication no/' /etc/ssh/sshd_config"
  run_cmd "${step}_reload" "sudo sshd -t && sudo systemctl restart ssh"
  run_cmd "${step}_verify" "sudo sshd -T | grep -E 'passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication'"
  ssh_password_disabled || {
    CURRENT_STEP="${step}"
    CURRENT_CMD="sudo sshd -T"
    echo "SSH password authentication is still enabled after deactivation attempt" >&2
    return 1
  }
  mark_step_done "${step}"
}

ensure_unlock() {
  local step="cmpunlocker_install"
  if [[ "${SKIP_UNLOCK}" == "1" ]]; then
    skip_step "${step}" "disabled with --skip-unlock"
    mark_step_done "${step}"
    return
  fi

  if verify_unlock_status; then
    skip_step "${step}" "cmpunlocker verify already passing"
    mark_step_done "${step}"
    return
  fi

  local profile
  profile="$(detect_unlock_profile)"
  run_cmd "${step}" "cd \"${HOME}/cmpunlocker\" && sudo ./install.sh --profile=${profile}"
  save_state_kv "NEEDS_COLD_POWEROFF" "1"
  save_state_kv "UNLOCK_PROFILE" "${profile}"
  mark_step_done "${step}"
  request_poweroff "${step}" "cmpunlocker installed with profile ${profile}. Cold power-off required before continuing."
}

verify_unlock() {
  local step="verify_unlock"
  if [[ "${SKIP_UNLOCK}" == "1" ]]; then
    skip_step "${step}" "unlock flow skipped"
    mark_step_done "${step}"
    return
  fi

  run_cmd "${step}" "cd \"${HOME}/cmpunlocker\" && sudo ./verify.sh"
  run_cmd "${step}_nvidia_smi" "nvidia-smi --query-gpu=name,memory.total,pcie.link.gen.current,pcie.link.gen.max --format=csv"
  save_state_kv "NEEDS_COLD_POWEROFF" "0"
  save_state_kv "PENDING_ACTION" "none"
  mark_step_done "${step}"
}

docker_mount_source() {
  findmnt -n -o SOURCE "${DOCKER_MOUNT}" 2>/dev/null || true
}

ensure_data_disk_migration() {
  local step="docker_data_disk"
  if [[ "${SKIP_STORAGE}" == "1" ]]; then
    skip_step "${step}" "disabled with --skip-storage"
    mark_step_done "${step}"
    return
  fi
  if [[ -z "${DATA_DISK}" ]]; then
    skip_step "${step}" "no --data-disk provided"
    mark_step_done "${step}"
    return
  fi

  local source
  source="$(docker_mount_source)"
  if [[ "${source}" == "${DATA_DISK}p1" || "${source}" == /dev/disk/by-uuid/* ]]; then
    if grep -q "${DOCKER_MOUNT} xfs .*pquota" /etc/fstab 2>/dev/null; then
      skip_step "${step}" "docker mount already appears migrated"
      mark_step_done "${step}"
      return
    fi
  fi

  run_cmd "${step}_partition" "sudo parted ${DATA_DISK} --script print >/dev/null 2>&1 || true; if [[ ! -b ${DATA_DISK}p1 ]]; then sudo parted ${DATA_DISK} --script mklabel gpt mkpart primary xfs 1MiB 100%; fi"
  run_cmd "${step}_mkfs" "sudo blkid ${DATA_DISK}p1 >/dev/null 2>&1 || sudo mkfs.xfs -f ${DATA_DISK}p1"
  run_cmd "${step}_mount_tmp" "sudo mkdir -p /mnt/vast-data && sudo mount ${DATA_DISK}p1 /mnt/vast-data 2>/dev/null || true"
  run_cmd "${step}_xfs_info" "sudo xfs_info /mnt/vast-data | grep ftype"
  run_cmd "${step}_copy1" "sudo rsync -aHAXx ${DOCKER_MOUNT}/ /mnt/vast-data/"
  run_cmd "${step}_stop_services" "sudo systemctl stop vastai 2>/dev/null || true; sudo systemctl stop docker.service || true; sudo systemctl stop docker.socket || true; sudo systemctl stop containerd.service || true"
  run_cmd "${step}_copy2" "sudo rsync -aHAXx --delete ${DOCKER_MOUNT}/ /mnt/vast-data/"
  run_cmd "${step}_fstab_backup" "sudo cp /etc/fstab /etc/fstab.bak"
  run_cmd "${step}_fstab" "UUID=\$(sudo blkid -s UUID -o value ${DATA_DISK}p1); sudo sed -i '\\|^/var/lib/docker-loop.xfs /var/lib/docker/ xfs loop,rw,auto,pquota 0 0\$| s|^|# |' /etc/fstab; if ! grep -q \"\${UUID} ${DOCKER_MOUNT} xfs defaults,pquota,nofail 0 2\" /etc/fstab; then printf '%s\n' \"UUID=\${UUID} ${DOCKER_MOUNT} xfs defaults,pquota,nofail 0 2\" | sudo tee -a /etc/fstab; fi"
  run_cmd "${step}_cutover" "sudo systemctl daemon-reload && sudo umount /mnt/vast-data || true && sudo umount ${DOCKER_MOUNT} && sudo mount ${DOCKER_MOUNT} && findmnt ${DOCKER_MOUNT}"
  run_cmd "${step}_restart_services" "sudo systemctl enable docker.socket && sudo systemctl start containerd && sudo systemctl start docker && sudo systemctl start vastai 2>/dev/null || true"
  run_cmd "${step}_verify" "sudo docker info | egrep 'Storage Driver|Docker Root Dir|Backing Filesystem'; findmnt ${DOCKER_MOUNT}; df -h ${DOCKER_MOUNT}"
  mark_step_done "${step}"
}

load_vast_installer_cmd() {
  if [[ -n "${VAST_INSTALLER_CMD}" ]]; then
    printf '%s' "${VAST_INSTALLER_CMD}"
    return
  fi
  if [[ -n "${VAST_INSTALLER_CMD_FILE}" ]]; then
    tr -d '\r' < "${VAST_INSTALLER_CMD_FILE}"
    return
  fi
  printf ''
}

print_vast_installer_prompt() {
  log "Vast host enrollment is the next step."
  log "Open the Vast host setup page for this machine and copy the generated installer command."
  log "Run the installer manually on the host once SSH key-only access is confirmed."
  log "Example command from Vast:"
  log "  wget https://console.vast.ai/install -O install"
  log "  sudo python3 install <TOKEN> --interactive"
  log "If you do want this script to run that step, rerun it with:"
  log "  --run-vast-installer --vast-installer-cmd 'wget https://console.vast.ai/install -O install; sudo python3 install <TOKEN> --interactive'"
}

ensure_vast_host() {
  local step="vast_host"
  if [[ "${SKIP_VAST_HOST}" == "1" ]]; then
    skip_step "${step}" "disabled with --skip-vast-host"
    mark_step_done "${step}"
    return
  fi

  if systemctl is-active --quiet vastai; then
    skip_step "${step}" "vastai service already active"
    mark_step_done "${step}"
    return
  fi

  local installer_cmd
  installer_cmd="$(load_vast_installer_cmd)"
  if [[ "${RUN_VAST_INSTALLER}" != "1" ]]; then
    CURRENT_STEP="${step}"
    CURRENT_CMD="Manual Vast host enrollment"
    print_vast_installer_prompt
    save_state_kv "PENDING_ACTION" "vast_host_manual"
    exit 40
  fi

  if [[ -z "${installer_cmd}" ]]; then
    CURRENT_STEP="${step}"
    CURRENT_CMD="Vast host installer command"
    print_vast_installer_prompt
    echo "Vast host enrollment was not run. Copy the installer command from the Vast setup page and pass it with --vast-installer-cmd or --vast-installer-cmd-file." >&2
    return
  fi

  run_cmd "${step}_installer" "${installer_cmd}"
  run_cmd "${step}_docker_status" "sudo systemctl status docker --no-pager"
  run_cmd "${step}_vast_status" "sudo systemctl status vastai --no-pager"
  mark_step_done "${step}"
}

ensure_vast_api_key() {
  local step="vast_api_key"
  if [[ -z "${HOST_API_KEY}" ]]; then
    skip_step "${step}" "no --host-api-key provided; set it manually if the installer does not do it"
    return
  fi
  if [[ ! -x "${HOME}/.local/bin/vastai" && ! -x /usr/local/bin/vastai && ! $(command -v vastai 2>/dev/null) ]]; then
    skip_step "${step}" "vastai CLI not available yet"
    return
  fi

  run_cmd "${step}" "export PATH=\"\$HOME/.local/bin:\$PATH\" && vastai set api-key ${HOST_API_KEY@Q}"
  mark_step_done "${step}"
}

print_success_summary() {
  log "Host readying flow completed."
  log "State/log directory: ${STATE_DIR}"
  log "Logs: ${LOG_DIR}"
  if [[ "${SKIP_VAST_HOST}" != "1" ]]; then
    log "If needed next: run Vast self-test and listing checks."
  fi
}

main() {
  parse_args "$@"
  require_root_tools
  prepare_state

  prechecks
  ensure_base_packages
  ensure_docker
  ensure_nvidia_repo
  ensure_pinned_driver
  verify_driver
  ensure_vast_cli
  ensure_cmpunlocker_repo
  ensure_unlock
  verify_unlock
  ensure_data_disk_migration
  ensure_ssh_key_handoff
  ensure_ssh_password_deactivated
  ensure_vast_host
  ensure_vast_api_key
  print_success_summary
}

main "$@"
