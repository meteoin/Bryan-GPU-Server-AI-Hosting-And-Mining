#!/usr/bin/env bash
# Install a laptop SSH key on a Bryan GPU host, test key login, then disable
# password SSH. Run this from the admin laptop, not from the GPU host.
# Use a unique --alias per host.
set -Eeuo pipefail

TARGET=""
KEY=""
ALIAS_NAME=""
DISABLE_PASSWORD=0
GENERATE=1

usage() {
  cat <<'EOF'
Usage:
  setup_ssh_key_access.sh USER@HOST --alias NAME [options]

Run from the admin laptop over VPN. One unique --alias per host:

  ./scripts/setup_ssh_key_access.sh flyanb@192.168.1.174 --alias rigv3 --disable-password
  ./scripts/setup_ssh_key_access.sh flyanb@192.168.1.81  --alias rigv4 --disable-password

Each alias gets its own laptop key (~/.ssh/id_ed25519_<alias>) and SSH config
Host block. After key login works, --disable-password prompts for the host
sudo password in this terminal, writes 00-key-only.conf, and proves password
SSH is rejected.

Options:
  --alias NAME            Required. Unique name for this host
  --key PATH              Private key (default: ~/.ssh/id_ed25519_<alias>)
  --disable-password      After key login works, disable password SSH
  --no-generate           Do not create the key; it must already exist
  --help                  Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key)
      KEY="$2"
      shift 2
      ;;
    --alias)
      ALIAS_NAME="$2"
      shift 2
      ;;
    --disable-password)
      DISABLE_PASSWORD=1
      shift
      ;;
    --no-generate)
      GENERATE=0
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "${TARGET}" ]]; then
        echo "Unexpected extra argument: $1" >&2
        exit 2
      fi
      TARGET="$1"
      shift
      ;;
  esac
done

[[ -n "${TARGET}" ]] || {
  usage >&2
  exit 2
}

log() {
  printf '[ssh-key-setup] %s\n' "$*"
}

fail() {
  printf '[ssh-key-setup] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "${TARGET}" == *@* ]] || fail "target must look like user@host"
[[ -n "${ALIAS_NAME}" ]] || fail "--alias is required so each host gets its own key and SSH config name"
[[ "${ALIAS_NAME}" =~ ^[A-Za-z0-9._-]+$ ]] || fail "--alias must be a simple hostname token"

HOST_PART="${TARGET##*@}"
USER_PART="${TARGET%@*}"
KEY="${KEY:-${HOME}/.ssh/id_ed25519_${ALIAS_NAME}}"
PUB="${KEY}.pub"
CONFIG="${HOME}/.ssh/config"

ssh_base() {
  ssh -o StrictHostKeyChecking=accept-new "$@"
}

key_login_works() {
  ssh_base -i "${KEY}" \
    -o IdentitiesOnly=yes \
    -o PreferredAuthentications=publickey \
    -o PasswordAuthentication=no \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    "${TARGET}" \
    'echo key-login-ok' >/dev/null 2>&1
}

ssh_config_hostname_for_alias() {
  local alias="$1"
  [[ -f "${CONFIG}" ]] || return 0
  awk -v want="${alias}" '
    $1 == "Host" {
      active = 0
      for (i = 2; i <= NF; i++) if ($i == want) active = 1
      next
    }
    active && $1 == "HostName" { print $2; exit }
  ' "${CONFIG}"
}

ensure_ssh_config_alias() {
  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"
  touch "${CONFIG}"
  chmod 600 "${CONFIG}"
  local existing
  existing="$(ssh_config_hostname_for_alias "${ALIAS_NAME}")"
  if [[ -n "${existing}" ]]; then
    if [[ "${existing}" == "${HOST_PART}" ]]; then
      log "SSH config Host ${ALIAS_NAME} already points at ${HOST_PART}"
      return
    fi
    fail "Host ${ALIAS_NAME} already points at ${existing}, not ${HOST_PART}. Use a unique --alias for this host, or edit ${CONFIG}."
  fi
  if grep -Eq "^Host[[:space:]]+${ALIAS_NAME}([[:space:]]|$)" "${CONFIG}"; then
    fail "Host ${ALIAS_NAME} exists in ${CONFIG} without a HostName. Fix that block or pick another --alias."
  fi
  cat >> "${CONFIG}" <<EOF

Host ${ALIAS_NAME}
  HostName ${HOST_PART}
  User ${USER_PART}
  IdentityFile ${KEY}
  IdentitiesOnly yes
EOF
  log "Added Host ${ALIAS_NAME} -> ${HOST_PART} in ${CONFIG}"
}

disable_password_ssh() {
  [[ -r /dev/tty ]] || fail "disable-password needs a real terminal for the host sudo prompt"
  local remote_path auth_file auth
  remote_path="$(ssh_base -i "${KEY}" -o IdentitiesOnly=yes "${TARGET}" 'mktemp /tmp/bryan-disable-password-ssh.XXXXXX')"
  remote_path="${remote_path//$'\r'/}"
  [[ -n "${remote_path}" ]] || fail "could not create a temp script on ${TARGET}"
  auth_file="/tmp/bryan-sshd-auth.txt"

  ssh_base -i "${KEY}" -o IdentitiesOnly=yes "${TARGET}" "cat > '${remote_path}' && chmod 700 '${remote_path}'" <<REMOTE
set -euo pipefail
sudo mkdir -p /etc/ssh/sshd_config.d
sudo tee /etc/ssh/sshd_config.d/00-key-only.conf >/dev/null <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
EOF
sudo rm -f /etc/ssh/sshd_config.d/99-key-only.conf
shopt -s nullglob
for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
  sudo sed -ri 's/^[[:space:]]*#?[[:space:]]*PasswordAuthentication[[:space:]]+.*/PasswordAuthentication no/' "\${f}"
done
sudo sshd -t
if systemctl list-unit-files ssh.service >/dev/null 2>&1; then
  sudo systemctl reload ssh
else
  sudo systemctl reload sshd
fi
sudo sshd -T | grep -E '^(passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|permitrootlogin) ' | sudo tee '${auth_file}' >/dev/null
sudo chmod 644 '${auth_file}'
rm -f '${remote_path}'
REMOTE

  log "Enter the host sudo password when prompted"
  if ! ssh_base -t -i "${KEY}" -o IdentitiesOnly=yes -o RequestTTY=yes \
    "${TARGET}" "sudo bash '${remote_path}'" </dev/tty; then
    ssh_base -i "${KEY}" -o IdentitiesOnly=yes "${TARGET}" "rm -f '${remote_path}'" >/dev/null 2>&1 || true
    fail "failed to disable password SSH on ${TARGET}"
  fi

  auth="$(ssh_base -i "${KEY}" -o IdentitiesOnly=yes "${TARGET}" "cat '${auth_file}'")"
  printf '%s\n' "${auth}"
  printf '%s\n' "${auth}" | grep -q '^passwordauthentication no$' \
    || fail "sshd still has PasswordAuthentication yes. Inspect /etc/ssh/sshd_config.d/ on ${TARGET}."

  log "Re-testing key login after sshd reload"
  key_login_works || fail "key login broke after disabling passwords. Use an existing session to recover."

  log "Confirming password SSH is rejected"
  local pw_err pw_rc
  set +e
  pw_err="$(ssh_base \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o ConnectTimeout=10 \
    "${TARGET}" true 2>&1)"
  pw_rc=$?
  set -e
  if [[ "${pw_rc}" -eq 0 ]]; then
    fail "password SSH still succeeded"
  fi
  if printf '%s' "${pw_err}" | grep -Eq '\(publickey,password\)|[[:space:]]password:'; then
    fail "sshd still offers password: ${pw_err}"
  fi
  if ! printf '%s' "${pw_err}" | grep -q 'Permission denied'; then
    fail "unexpected password-test result: ${pw_err}"
  fi
  log "Password SSH rejected"
}

if [[ ! -f "${KEY}" ]]; then
  [[ "${GENERATE}" == "1" ]] || fail "private key not found: ${KEY}"
  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"
  log "Creating ${KEY} with an empty passphrase"
  ssh-keygen -t ed25519 -f "${KEY}" -C "$(id -un)-${ALIAS_NAME}" -N ""
fi
[[ -f "${PUB}" ]] || fail "public key not found: ${PUB}"

if key_login_works; then
  log "Key login already works; skipping ssh-copy-id"
else
  log "Installing public key on ${TARGET} (host account password)"
  if ! ssh-copy-id -i "${PUB}" \
    -o IdentitiesOnly=yes \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    "${TARGET}"; then
    fail "ssh-copy-id failed. Check VPN, host password, and that you ran this from the laptop."
  fi
fi

log "Testing key-only login"
key_login_works || fail "key login failed. Password SSH was not disabled. Fix authorized_keys and retry."
log "Key login ok"

ensure_ssh_config_alias

if [[ "${DISABLE_PASSWORD}" == "1" ]]; then
  log "Disabling password SSH on ${TARGET}"
  disable_password_ssh
fi

log "Done. Test: ssh ${ALIAS_NAME}"
log "Or: ssh -i ${KEY} -o IdentitiesOnly=yes ${TARGET}"
