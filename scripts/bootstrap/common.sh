# Shared paths and helpers for Bryan GPU setup bootstrap.
# shellcheck shell=bash

BRYAN_SETUP_NAME="bryan-gpu-setup"
BRYAN_DEFAULT_REPO="${BRYAN_SETUP_REPO:-https://github.com/meteoin/Bryan-GPU-Server-AI-Hosting-And-Mining.git}"
BRYAN_DEFAULT_REF="${BRYAN_SETUP_REF:-main}"
BRYAN_SRBMINER_VERSION="${BRYAN_SRBMINER_VERSION:-3.6.2}"
BRYAN_SRBMINER_URL="${BRYAN_SRBMINER_URL:-https://github.com/doktor83/SRBMiner-Multi/releases/download/3.6.2/SRBMiner-Multi-3-6-2-Linux.tar.gz}"

bryan_bootstrap_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

bryan_repo_root() {
  local bootstrap_dir
  bootstrap_dir="$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")" && pwd)"
  if [[ "$(basename "${bootstrap_dir}")" == "bootstrap" ]]; then
    cd "${bootstrap_dir}/../.." && pwd
  else
    cd "${bootstrap_dir}" && pwd
  fi
}

bryan_init_paths() {
  if [[ "$(id -u)" -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    BRYAN_USER="${SUDO_USER}"
    BRYAN_HOME="$(eval echo "~${SUDO_USER}")"
  else
    BRYAN_HOME="${HOME}"
    BRYAN_USER="${USER:-$(id -un)}"
  fi
  BRYAN_CONFIG_DIR="${XDG_CONFIG_HOME:-${BRYAN_HOME}/.config}"
  BRYAN_BIN_DIR="${BRYAN_SETUP_BIN:-${BRYAN_HOME}/.local/bin}"
  if [[ -n "${BRYAN_SETUP_ROOT:-}" ]]; then
    local root="${BRYAN_SETUP_ROOT%/}"
    BRYAN_SRC_DIR="${BRYAN_SETUP_SRC:-${root}/src}"
    BRYAN_LIB_DIR="${BRYAN_SETUP_LIB:-${root}/lib}"
    BRYAN_STATE_DIR="${BRYAN_SETUP_STATE:-${root}/state}"
    BRYAN_SRBMINER_DIR="${BRYAN_SRBMINER_DIR:-${root}/srbminer}"
  else
    BRYAN_SRC_DIR="${BRYAN_SETUP_SRC:-${BRYAN_HOME}/.local/share/${BRYAN_SETUP_NAME}/src}"
    BRYAN_LIB_DIR="${BRYAN_SETUP_LIB:-${BRYAN_HOME}/.local/lib/${BRYAN_SETUP_NAME}}"
    BRYAN_STATE_DIR="${BRYAN_SETUP_STATE:-${BRYAN_HOME}/.local/state/${BRYAN_SETUP_NAME}}"
    BRYAN_SRBMINER_DIR="${BRYAN_SRBMINER_DIR:-${BRYAN_HOME}/srbminer}"
  fi
  BRYAN_ENV_FILE="${BRYAN_ENV_FILE:-${BRYAN_CONFIG_DIR}/vast-prl-host-miner.env}"
  BRYAN_INSTALLED_FILE="${BRYAN_STATE_DIR}/installed.json"
  BRYAN_UPDATE_LOG="${BRYAN_STATE_DIR}/update.log"
  BRYAN_UPDATE_LOCK="${BRYAN_STATE_DIR}/update.lock"
  BRYAN_SRBMINER_BIN="${BRYAN_SRBMINER_BIN:-${BRYAN_SRBMINER_DIR}/SRBMiner-MULTI}"
  BRYAN_MINER_SERVICE="${BRYAN_MINER_SERVICE:-vast-prl-host-miner.service}"
  BRYAN_UPDATE_SERVICE="${BRYAN_UPDATE_SERVICE:-bryan-gpu-setup-update.service}"
  BRYAN_UPDATE_TIMER="${BRYAN_UPDATE_TIMER:-bryan-gpu-setup-update.timer}"
}

bryan_log() {
  local line
  line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  printf '%s\n' "${line}"
  if [[ -n "${BRYAN_UPDATE_LOG:-}" ]]; then
    mkdir -p "$(dirname "${BRYAN_UPDATE_LOG}")"
    printf '%s\n' "${line}" >> "${BRYAN_UPDATE_LOG}"
  fi
}

bryan_fail() {
  bryan_log "ERROR: $*"
  exit 1
}

bryan_python() {
  command -v python3 >/dev/null 2>&1 || bryan_fail "python3 is required"
  python3 "$@"
}

bryan_prompt() {
  local message="$1"
  local default="${2:-}"
  local reply=""
  if [[ "${BRYAN_YES:-0}" == "1" ]]; then
    printf '%s\n' "${default}"
    return 0
  fi
  if [[ ! -e /dev/tty ]]; then
    printf '%s\n' "${default}"
    return 0
  fi
  if [[ -n "${default}" ]]; then
    printf '%s [%s]: ' "${message}" "${default}" > /dev/tty
  else
    printf '%s: ' "${message}" > /dev/tty
  fi
  read -r reply < /dev/tty || true
  if [[ -z "${reply}" ]]; then
    printf '%s\n' "${default}"
  else
    printf '%s\n' "${reply}"
  fi
}

bryan_confirm() {
  local message="$1"
  local default="${2:-n}"
  local reply
  reply="$(bryan_prompt "${message} (y/n)" "${default}")"
  case "${reply}" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

bryan_can_sudo() {
  command -v sudo >/dev/null 2>&1 || return 1
  sudo -n true >/dev/null 2>&1
}

bryan_run_sudo() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif bryan_can_sudo; then
    sudo "$@"
  else
    sudo "$@"
  fi
}

bryan_github_repo_slug() {
  local repo="${1:-${BRYAN_DEFAULT_REPO}}"
  repo="${repo%.git}"
  repo="${repo#git@github.com:}"
  repo="${repo#https://github.com/}"
  repo="${repo#http://github.com/}"
  printf '%s\n' "${repo}"
}

bryan_raw_manifest_url() {
  local repo ref slug
  repo="${1:-${BRYAN_DEFAULT_REPO}}"
  ref="${2:-${BRYAN_DEFAULT_REF}}"
  slug="$(bryan_github_repo_slug "${repo}")"
  printf 'https://raw.githubusercontent.com/%s/%s/manifest.json\n' "${slug}" "${ref}"
}

bryan_release_manifest_url() {
  local repo slug
  repo="${1:-${BRYAN_DEFAULT_REPO}}"
  slug="$(bryan_github_repo_slug "${repo}")"
  printf 'https://github.com/%s/releases/latest/download/manifest.json\n' "${slug}"
}

bryan_curl() {
  local args=(curl -fsSL --connect-timeout 15 --retry 2)
  if [[ -n "${GITHUB_TOKEN:-${GH_TOKEN:-}}" ]]; then
    args+=(-H "Authorization: Bearer ${GITHUB_TOKEN:-${GH_TOKEN}}")
    args+=(-H "Accept: application/vnd.github+json")
  fi
  "${args[@]}" "$@"
}

bryan_json_get() {
  local file="$1"
  local expr="$2"
  bryan_python - "${file}" "${expr}" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
expr = sys.argv[2]
if not path.exists():
    raise SystemExit(0)
data = json.loads(path.read_text())
current = data
for part in expr.split("."):
    if part == "":
        continue
    if isinstance(current, dict):
        current = current.get(part)
    else:
        current = None
        break
    if current is None:
        break
if current is None:
    print("")
elif isinstance(current, (dict, list)):
    print(json.dumps(current))
else:
    print(current)
PY
}

bryan_write_json() {
  local file="$1"
  bryan_python - "${file}" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(sys.stdin.read())
path.parent.mkdir(parents=True, exist_ok=True)
tmp = path.with_suffix(path.suffix + ".tmp")
tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
tmp.replace(path)
PY
}

bryan_load_installed() {
  if [[ -f "${BRYAN_INSTALLED_FILE}" ]]; then
    cat "${BRYAN_INSTALLED_FILE}"
  else
    printf '{}\n'
  fi
}

bryan_render_template() {
  local src="$1"
  local dest="$2"
  local user_name="${3:-${BRYAN_USER}}"
  local home_dir="${4:-${BRYAN_HOME}}"
  local lib_dir="${5:-${BRYAN_LIB_DIR}}"
  local bin_dir="${6:-${BRYAN_BIN_DIR}}"
  local env_file="${7:-${BRYAN_ENV_FILE}}"
  local path_value="${home_dir}/.local/bin:/usr/local/bin:/usr/bin:/bin"
  sed \
    -e "s|@USER@|${user_name}|g" \
    -e "s|@HOME@|${home_dir}|g" \
    -e "s|@LIB_DIR@|${lib_dir}|g" \
    -e "s|@BIN_DIR@|${bin_dir}|g" \
    -e "s|@ENV_FILE@|${env_file}|g" \
    -e "s|@PATH@|${path_value}|g" \
    "${src}" > "${dest}"
}

bryan_atomic_copy() {
  local src="$1"
  local dest="$2"
  local mode="${3:-}"
  local tmp
  mkdir -p "$(dirname "${dest}")"
  tmp="$(mktemp "${dest}.XXXXXX")"
  cp "${src}" "${tmp}"
  if [[ -n "${mode}" ]]; then
    chmod "${mode}" "${tmp}"
  elif [[ -x "${src}" ]]; then
    chmod +x "${tmp}"
  fi
  mv "${tmp}" "${dest}"
}

bryan_lib_filename() {
  local rel="$1"
  basename "${rel}"
}

bryan_miner_state_file() {
  local machine_id=""
  if [[ -f "${BRYAN_ENV_FILE}" ]]; then
    machine_id="$(awk -F= '/^MACHINE_ID=/{print $2; exit}' "${BRYAN_ENV_FILE}" | tr -d '"' | tr -d "'")"
  fi
  if [[ -z "${machine_id}" ]]; then
    printf '\n'
    return 0
  fi
  local base="${XDG_STATE_HOME:-${BRYAN_HOME}/.local/state}"
  printf '%s\n' "${base}/vast-host-miner/${machine_id}/state.json"
}

bryan_host_is_busy() {
  local state_file
  state_file="$(bryan_miner_state_file)"
  [[ -n "${state_file}" && -f "${state_file}" ]] || return 1
  bryan_python - "${state_file}" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
observed = str(data.get("observed_state", "")).strip().lower()
raise SystemExit(0 if observed == "busy" else 1)
PY
}

bryan_systemctl() {
  if [[ "$(id -u)" -eq 0 ]]; then
    systemctl "$@"
  elif bryan_can_sudo || sudo -n true >/dev/null 2>&1; then
    sudo systemctl "$@"
  else
    systemctl --user "$@"
  fi
}
