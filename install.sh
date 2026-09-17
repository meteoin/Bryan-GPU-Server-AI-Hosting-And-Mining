#!/usr/bin/env bash
# Public curl entrypoint. Clones a known ref, then execs the real installer.
set -Eeuo pipefail

BRYAN_DEFAULT_REPO="${BRYAN_SETUP_REPO:-https://github.com/meteoin/Bryan-GPU-Server-AI-Hosting-And-Mining.git}"
BRYAN_SRC_DIR="${BRYAN_SETUP_SRC:-${HOME}/.local/share/bryan-gpu-setup/src}"

repo_slug() {
  local repo="${1%.git}"
  repo="${repo#git@github.com:}"
  repo="${repo#https://github.com/}"
  repo="${repo#http://github.com/}"
  printf '%s\n' "${repo}"
}

latest_ref() {
  if [[ -n "${BRYAN_SETUP_REF:-}" ]]; then
    printf '%s\n' "${BRYAN_SETUP_REF}"
    return 0
  fi
  local slug api tag
  slug="$(repo_slug "${BRYAN_DEFAULT_REPO}")"
  api="https://api.github.com/repos/${slug}/releases/latest"
  local curl_args=(curl -fsSL --connect-timeout 10)
  if [[ -n "${GITHUB_TOKEN:-${GH_TOKEN:-}}" ]]; then
    curl_args+=(-H "Authorization: Bearer ${GITHUB_TOKEN:-${GH_TOKEN}}")
    curl_args+=(-H "Accept: application/vnd.github+json")
  fi
  tag="$("${curl_args[@]}" "${api}" 2>/dev/null | python3 -c 'import json,sys
try:
    data=json.load(sys.stdin)
    print(data.get("tag_name") or "")
except Exception:
    print("")
' || true)"
  if [[ -n "${tag}" ]]; then
    printf '%s\n' "${tag}"
  else
    printf 'main\n'
  fi
}

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SELF_DIR}/scripts/bootstrap/install.sh" ]]; then
  exec bash "${SELF_DIR}/scripts/bootstrap/install.sh" "$@"
fi

command -v git >/dev/null 2>&1 || {
  echo "git is required to install Bryan GPU setup" >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  echo "python3 is required to install Bryan GPU setup" >&2
  exit 1
}

REF="$(latest_ref)"
export BRYAN_SETUP_REF="${REF}"
mkdir -p "$(dirname "${BRYAN_SRC_DIR}")"
if [[ -d "${BRYAN_SRC_DIR}/.git" ]]; then
  git -C "${BRYAN_SRC_DIR}" remote set-url origin "${BRYAN_DEFAULT_REPO}" >/dev/null 2>&1 || true
  git -C "${BRYAN_SRC_DIR}" fetch --depth 1 origin "${REF}"
  git -C "${BRYAN_SRC_DIR}" checkout -q FETCH_HEAD || git -C "${BRYAN_SRC_DIR}" checkout -q "${REF}"
else
  rm -rf "${BRYAN_SRC_DIR}"
  git clone --depth 1 --branch "${REF}" "${BRYAN_DEFAULT_REPO}" "${BRYAN_SRC_DIR}"
fi

exec bash "${BRYAN_SRC_DIR}/scripts/bootstrap/install.sh" "$@"
