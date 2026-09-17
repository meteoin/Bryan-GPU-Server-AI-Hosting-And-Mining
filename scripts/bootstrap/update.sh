#!/usr/bin/env bash
# Fetch repo update info and apply only components whose version changed.
set -Eeuo pipefail

BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${BOOTSTRAP_DIR}/common.sh"
bryan_init_paths

MODE="apply"
TIMER_AUTO=0
for arg in "$@"; do
  case "${arg}" in
    --check) MODE="check" ;;
    --apply) MODE="apply" ;;
    --status) MODE="status" ;;
    --auto) TIMER_AUTO=1 ;;
    --help|-h)
      cat <<'EOF'
Usage:
  update.sh --check | --apply | --status | --auto
EOF
      exit 0
      ;;
  esac
done

mkdir -p "${BRYAN_STATE_DIR}"

if command -v flock >/dev/null 2>&1; then
  exec 9>"${BRYAN_UPDATE_LOCK}"
  if ! flock -n 9; then
    bryan_log "Another update process is running"
    exit 0
  fi
fi

if [[ ! -f "${BRYAN_INSTALLED_FILE}" ]]; then
  bryan_fail "no install state at ${BRYAN_INSTALLED_FILE}; run the installer first"
fi

REPO="$(bryan_json_get "${BRYAN_INSTALLED_FILE}" repo)"
REF="$(bryan_json_get "${BRYAN_INSTALLED_FILE}" ref)"
PROFILE="$(bryan_json_get "${BRYAN_INSTALLED_FILE}" profile)"
SRC_DIR="$(bryan_json_get "${BRYAN_INSTALLED_FILE}" src_dir)"
LIB_DIR="$(bryan_json_get "${BRYAN_INSTALLED_FILE}" lib_dir)"
UPDATE_AUTO="$(bryan_json_get "${BRYAN_INSTALLED_FILE}" update_auto)"
UPDATE_SRBMINER="$(bryan_json_get "${BRYAN_INSTALLED_FILE}" update_srbminer)"
REPO="${REPO:-${BRYAN_DEFAULT_REPO}}"
REF="${REF:-${BRYAN_DEFAULT_REF}}"
SRC_DIR="${SRC_DIR:-${BRYAN_SRC_DIR}}"
LIB_DIR="${LIB_DIR:-${BRYAN_LIB_DIR}}"
BRYAN_LIB_DIR="${LIB_DIR}"
BRYAN_SRC_DIR="${SRC_DIR}"

REMOTE_MANIFEST="$(mktemp)"
cleanup() {
  rm -f "${REMOTE_MANIFEST}"
}
trap cleanup EXIT

fetch_remote_manifest() {
  mkdir -p "${SRC_DIR}"
  if [[ -d "${SRC_DIR}/.git" ]]; then
    bryan_log "Fetching ${REPO} ${REF}"
    git -C "${SRC_DIR}" remote set-url origin "${REPO}" >/dev/null 2>&1 || git -C "${SRC_DIR}" remote add origin "${REPO}"
    if git -C "${SRC_DIR}" fetch --depth 1 origin "${REF}"; then
      if git -C "${SRC_DIR}" show "origin/${REF}:manifest.json" > "${REMOTE_MANIFEST}" 2>/dev/null; then
        if ! git -C "${SRC_DIR}" merge --ff-only "origin/${REF}" >/dev/null 2>&1; then
          bryan_log "Fast-forward failed (likely a force-push); resetting clone to origin/${REF}"
          git -C "${SRC_DIR}" checkout -q -B "${REF}" "origin/${REF}" || git -C "${SRC_DIR}" reset --hard "origin/${REF}"
        fi
        return 0
      fi
    fi
  elif [[ -f "${SRC_DIR}/manifest.json" ]]; then
    cp "${SRC_DIR}/manifest.json" "${REMOTE_MANIFEST}"
    return 0
  fi

  local release_url raw_url
  release_url="$(bryan_release_manifest_url "${REPO}")"
  raw_url="$(bryan_raw_manifest_url "${REPO}" "${REF}")"
  if bryan_curl "${release_url}" > "${REMOTE_MANIFEST}" 2>/dev/null; then
    bryan_log "Fetched release manifest ${release_url}"
    return 0
  fi
  if bryan_curl "${raw_url}" > "${REMOTE_MANIFEST}"; then
    bryan_log "Fetched repo manifest ${raw_url}"
    return 0
  fi
  bryan_fail "unable to fetch update manifest from ${REPO}"
}

print_status() {
  bryan_python - "${BRYAN_INSTALLED_FILE}" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
print(f"profile={data.get('profile')}")
print(f"release={data.get('release')}")
print(f"repo={data.get('repo')}")
print(f"ref={data.get('ref')}")
print(f"update_auto={data.get('update_auto')}")
print("components:")
for name, version in sorted((data.get("components") or {}).items()):
    print(f"  {name}={version}")
pending = data.get("pending_restart") or []
if pending:
    print("pending_restart=" + ",".join(pending))
PY
}

plan_updates() {
  bryan_python - "${BRYAN_INSTALLED_FILE}" "${REMOTE_MANIFEST}" "${PROFILE}" "${UPDATE_SRBMINER}" <<'PY'
import json
import sys
from pathlib import Path

def parse_version(value: str):
    parts = []
    for item in str(value or "0").replace("-", ".").split("."):
        digits = "".join(ch for ch in item if ch.isdigit())
        parts.append(int(digits) if digits else 0)
    return tuple(parts)

installed = json.loads(Path(sys.argv[1]).read_text())
manifest = json.loads(Path(sys.argv[2]).read_text())
profile = sys.argv[3]
update_srbminer = sys.argv[4].lower() in {"1", "true", "yes"}
local_components = installed.get("components") or {}
plan = []
for name, spec in (manifest.get("components") or {}).items():
    profiles = spec.get("profiles") or []
    if profile not in profiles:
        continue
    remote_version = str(spec.get("version") or "")
    local_version = str(local_components.get(name) or "")
    auto_update = bool(spec.get("auto_update", True))
    if name == "srbminer" and not update_srbminer:
        auto_update = False
    newer = parse_version(remote_version) > parse_version(local_version)
    if not newer:
        continue
    plan.append({
        "name": name,
        "from": local_version or "none",
        "to": remote_version,
        "auto_update": auto_update,
        "files": spec.get("files") or [],
        "restart": spec.get("restart") or "",
        "idle_only_restart": bool(spec.get("idle_only_restart")),
        "kind": spec.get("kind") or "files",
        "url": spec.get("url") or "",
    })
print(json.dumps({"release": manifest.get("release"), "channel": manifest.get("channel"), "plan": plan}))
PY
}

copy_files_from_src() {
  local component_json="$1"
  local rel tmp dest base
  while IFS= read -r rel; do
    [[ -n "${rel}" ]] || continue
    tmp="$(mktemp)"
    if git -C "${SRC_DIR}" show "origin/${REF}:${rel}" > "${tmp}" 2>/dev/null; then
      true
    elif [[ -f "${SRC_DIR}/${rel}" ]]; then
      cp "${SRC_DIR}/${rel}" "${tmp}"
    else
      rm -f "${tmp}"
      continue
    fi
    base="$(basename "${rel}")"
    case "${base}" in
      vast_idle_host_miner.py|vast_prl_host_miner_launcher.sh|gpu_tuning_helper.py|terminal_miner_control.py)
        dest="${LIB_DIR}/${base}"
        mkdir -p "$(dirname "${dest}")"
        if [[ "${base}" == *.sh ]]; then
          chmod 755 "${tmp}"
        fi
        mv "${tmp}" "${dest}"
        bryan_log "Updated ${dest}"
        ;;
      *)
        rm -f "${tmp}"
        ;;
    esac
  done < <(bryan_python -c 'import json,sys; print("\n".join(json.loads(sys.argv[1]).get("files") or []))' "${component_json}")
}

refresh_templated_units() {
  local repo_root="${SRC_DIR}"
  if [[ ! -f "${repo_root}/systemd/vast-prl-host-miner.service.in" ]]; then
    repo_root="${BOOTSTRAP_DIR}/../.."
  fi
  local miner_rendered="${BRYAN_STATE_DIR}/vast-prl-host-miner.service"
  local update_rendered="${BRYAN_STATE_DIR}/bryan-gpu-setup-update.service"
  if [[ -f "${repo_root}/systemd/vast-prl-host-miner.service.in" ]]; then
    bryan_render_template "${repo_root}/systemd/vast-prl-host-miner.service.in" "${miner_rendered}"
    if [[ -d /etc/systemd/system ]]; then
      bryan_run_sudo cp "${miner_rendered}" "/etc/systemd/system/${BRYAN_MINER_SERVICE}" || true
    fi
  fi
  if [[ -f "${repo_root}/systemd/bryan-gpu-setup-update.service.in" ]]; then
    bryan_render_template "${repo_root}/systemd/bryan-gpu-setup-update.service.in" "${update_rendered}"
    if [[ -d /etc/systemd/system ]]; then
      bryan_run_sudo cp "${update_rendered}" "/etc/systemd/system/${BRYAN_UPDATE_SERVICE}" || true
      bryan_run_sudo cp "${repo_root}/systemd/bryan-gpu-setup-update.timer" "/etc/systemd/system/${BRYAN_UPDATE_TIMER}" || true
    fi
  fi
  mkdir -p "${BRYAN_BIN_DIR}"
  if git -C "${SRC_DIR}" show "origin/${REF}:scripts/controlpanel" > /dev/null 2>&1; then
    local tmp
    tmp="$(mktemp "${BRYAN_BIN_DIR}/controlpanel.XXXXXX")"
    git -C "${SRC_DIR}" show "origin/${REF}:scripts/controlpanel" > "${tmp}"
    chmod 755 "${tmp}"
    mv "${tmp}" "${BRYAN_BIN_DIR}/controlpanel"
  fi
  bryan_install_cli_from_tree "${repo_root}"
  bryan_systemctl daemon-reload || true
}

maybe_restart_miner() {
  local busy=0
  if bryan_host_is_busy; then
    busy=1
  fi
  if [[ "${busy}" == "1" ]]; then
    bryan_log "Host is rented/busy; deferring miner service restart"
    bryan_python - "${BRYAN_INSTALLED_FILE}" "${BRYAN_MINER_SERVICE}" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
service = sys.argv[2]
data = json.loads(path.read_text())
pending = data.setdefault("pending_restart", [])
if service not in pending:
    pending.append(service)
path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
PY
    return 1
  fi
  bryan_log "Restarting ${BRYAN_MINER_SERVICE}"
  bryan_systemctl restart "${BRYAN_MINER_SERVICE}" || true
  bryan_python - "${BRYAN_INSTALLED_FILE}" "${BRYAN_MINER_SERVICE}" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
service = sys.argv[2]
data = json.loads(path.read_text())
pending = [item for item in data.get("pending_restart", []) if item != service]
data["pending_restart"] = pending
path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
PY
  return 0
}

record_component_version() {
  local name="$1"
  local version="$2"
  local release="$3"
  bryan_python - "${BRYAN_INSTALLED_FILE}" "${name}" "${version}" "${release}" <<'PY'
import json
import sys
import time
from pathlib import Path

path = Path(sys.argv[1])
name = sys.argv[2]
version = sys.argv[3]
release = sys.argv[4]
data = json.loads(path.read_text())
data.setdefault("components", {})[name] = version
if release:
    data["release"] = release
data["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
PY
}

if [[ "${MODE}" == "status" ]]; then
  print_status
  exit 0
fi

fetch_remote_manifest
PLAN_JSON="$(plan_updates)"
PLAN_COUNT="$(bryan_python -c 'import json,sys; print(len(json.loads(sys.argv[1]).get("plan", [])))' "${PLAN_JSON}")"
RELEASE="$(bryan_python -c 'import json,sys; print(json.loads(sys.argv[1]).get("release") or "")' "${PLAN_JSON}")"

if [[ "${PLAN_COUNT}" -eq 0 ]]; then
  bryan_log "No component updates found for profile ${PROFILE}"
  if [[ "${MODE}" == "check" ]]; then
    print_status
  fi
  # still retry a deferred restart if the host is now idle
  PENDING="$(bryan_json_get "${BRYAN_INSTALLED_FILE}" pending_restart)"
  if [[ "${MODE}" == "apply" && "${PENDING}" == *"${BRYAN_MINER_SERVICE}"* ]]; then
    maybe_restart_miner || true
  fi
  exit 0
fi

bryan_log "Update plan for release ${RELEASE}:"
bryan_python -c 'import json,sys
plan=json.loads(sys.argv[1])
for item in plan["plan"]:
    flag="" if item["auto_update"] else " (notify only)"
    print("  %s: %s -> %s%s" % (item["name"], item["from"], item["to"], flag))
' "${PLAN_JSON}"

if [[ "${MODE}" == "check" ]]; then
  exit 0
fi

if [[ "${TIMER_AUTO}" == "1" && ( "${UPDATE_AUTO}" == "False" || "${UPDATE_AUTO}" == "false" || "${UPDATE_AUTO}" == "0" ) ]]; then
  bryan_log "Auto-update is disabled in installed.json; not applying"
  exit 0
fi

mapfile -t UPDATE_ITEMS < <(bryan_python -c 'import json,sys; [print(json.dumps(item)) for item in json.loads(sys.argv[1])["plan"]]' "${PLAN_JSON}")
for item in "${UPDATE_ITEMS[@]}"; do
  name="$(bryan_python -c 'import json,sys; print(json.loads(sys.argv[1])["name"])' "${item}")"
  version="$(bryan_python -c 'import json,sys; print(json.loads(sys.argv[1])["to"])' "${item}")"
  auto="$(bryan_python -c 'import json,sys; print("1" if json.loads(sys.argv[1])["auto_update"] else "0")' "${item}")"
  kind="$(bryan_python -c 'import json,sys; print(json.loads(sys.argv[1]).get("kind") or "files")' "${item}")"
  restart="$(bryan_python -c 'import json,sys; print(json.loads(sys.argv[1]).get("restart") or "")' "${item}")"
  if [[ "${auto}" != "1" ]]; then
    bryan_log "Component ${name} ${version} is available; not auto-applied"
    continue
  fi
  bryan_log "Updating ${name} to ${version}"
  if [[ "${kind}" == "external-binary" ]]; then
    bryan_log "SRBMiner auto-update is opt-in; skipping binary replace"
    continue
  fi
  copy_files_from_src "${item}" >/dev/null
  if [[ "${name}" == "installer" || "${name}" == "systemd-unit" ]]; then
    refresh_templated_units
  fi
  record_component_version "${name}" "${version}" "${RELEASE}"
  if [[ -n "${restart}" ]]; then
    maybe_restart_miner || true
  fi
done

mkdir -p "${LIB_DIR}"
if [[ ! -f "${LIB_DIR}/terminal_miner_control.py" ]]; then
  if git -C "${SRC_DIR}" show "origin/${REF}:scripts/terminal_miner_control.py" > "${LIB_DIR}/terminal_miner_control.py" 2>/dev/null; then
    bryan_log "Installed terminal app to ${LIB_DIR}/terminal_miner_control.py"
  fi
fi
bryan_install_cli_from_tree "${SRC_DIR}"
if [[ -f "${LIB_DIR}/terminal_miner_control.py" ]]; then
  bryan_log "controlpanel: python3 ${LIB_DIR}/terminal_miner_control.py"
else
  bryan_log "WARNING: terminal_miner_control.py is still missing from ${LIB_DIR}"
fi

bryan_log "Update pass complete"
print_status
