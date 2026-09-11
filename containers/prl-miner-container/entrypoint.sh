#!/usr/bin/env bash
set -Eeuo pipefail

MINER_BIN="/opt/prl-miner/p40-miner"

if [[ ! -x "${MINER_BIN}" ]]; then
  echo "PRL miner binary not found at ${MINER_BIN}" >&2
  exit 1
fi

if [[ $# -gt 0 ]]; then
  exec "${MINER_BIN}" "$@"
fi

if [[ -z "${PRL_WALLET:-}" ]]; then
  echo "PRL_WALLET is required when no command-line args are passed." >&2
  echo "Example:" >&2
  echo "  docker run --rm --gpus all local/prl-open-pearl-miner:latest --wallet prl1... --worker rigv4 --pool pearl-us-central.luckypool.io:3360" >&2
  exit 2
fi

WORKER="${PRL_WORKER:-$(hostname)}"
cmd=("${MINER_BIN}" "--wallet" "${PRL_WALLET}" "--worker" "${WORKER}")

if [[ -n "${PRL_POOL:-}" ]]; then
  cmd+=("--pool" "${PRL_POOL}")
fi

if [[ -n "${PRL_DEVICES:-}" ]]; then
  cmd+=("--devices" "${PRL_DEVICES}")
fi

if [[ -n "${PRL_REGION:-}" ]]; then
  cmd+=("--region" "${PRL_REGION}")
fi

if [[ -n "${PRL_SOLO:-}" ]]; then
  cmd+=("--solo" "${PRL_SOLO}")
fi

if [[ -n "${PRL_EXTRA_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  extra_args=( ${PRL_EXTRA_ARGS} )
  cmd+=("${extra_args[@]}")
fi

exec "${cmd[@]}"
