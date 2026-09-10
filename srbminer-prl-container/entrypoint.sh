#!/usr/bin/env bash
set -Eeuo pipefail

MINER_BIN="/opt/srbminer/SRBMiner-MULTI"

if [[ ! -x "${MINER_BIN}" ]]; then
  echo "SRBMiner binary not found at ${MINER_BIN}" >&2
  exit 1
fi

if [[ $# -gt 0 ]]; then
  exec "${MINER_BIN}" "$@"
fi

if [[ -z "${PRL_WALLET:-}" ]]; then
  echo "PRL_WALLET is required when no command-line args are passed." >&2
  echo "Example:" >&2
  echo "  docker run --rm --gpus all local/prl-srbminer:latest --algorithm-gpu pearlhash --wallet prl1... --worker rigv4 --pool pearl-us-west.luckypool.io:3360" >&2
  exit 2
fi

WORKER="${PRL_WORKER:-$(hostname)}"
POOL="${PRL_POOL:-pearl-us-west.luckypool.io:3360}"

cmd=(
  "${MINER_BIN}"
  "--algorithm-gpu" "pearlhash"
  "--wallet" "${PRL_WALLET}"
  "--worker" "${WORKER}"
  "--pool" "${POOL}"
)

if [[ -n "${PRL_EXTRA_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  extra_args=( ${PRL_EXTRA_ARGS} )
  cmd+=("${extra_args[@]}")
fi

exec "${cmd[@]}"
