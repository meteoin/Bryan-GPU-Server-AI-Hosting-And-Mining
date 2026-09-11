#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

PYTHON_BIN="${PYTHON_BIN:-/usr/bin/python3}"
WATCHER_SCRIPT="${WATCHER_SCRIPT:-$SCRIPT_DIR/vast_idle_host_miner.py}"
GPU_TUNING_HELPER="${GPU_TUNING_HELPER:-$SCRIPT_DIR/gpu_tuning_helper.py}"
MINER_BIN="${MINER_BIN:-$HOME/srbminer/SRBMiner-MULTI}"
MACHINE_ID="${MACHINE_ID:-}"
PRL_WALLET="${PRL_WALLET:-}"
WORKER_NAME="${WORKER_NAME:-$(hostname -s)}"
POOL="${POOL:-pearl-us-west.luckypool.io:3360}"
POOL_PASSWORD="${POOL_PASSWORD:-x}"
GPU_POWER_LIMIT="${GPU_POWER_LIMIT:-}"
GPU_MEMORY_CLOCK="${GPU_MEMORY_CLOCK:-}"
GPU_CORE_CLOCK="${GPU_CORE_CLOCK:-}"
POLL_SECONDS="${POLL_SECONDS:-5}"
MIN_IDLE_POLLS="${MIN_IDLE_POLLS:-2}"
MIN_BUSY_POLLS="${MIN_BUSY_POLLS:-1}"
RECONCILE_INTERVAL="${RECONCILE_INTERVAL:-60}"
STOP_TIMEOUT_SECONDS="${STOP_TIMEOUT_SECONDS:-20}"
STATE_DIR="${STATE_DIR:-$HOME/.local/state/vast-host-miner/${MACHINE_ID}}"
DRY_RUN="${DRY_RUN:-0}"

fail() {
  printf '[vast-prl-launcher] %s\n' "$1" >&2
  exit 1
}

[[ -n "$MACHINE_ID" ]] || fail "MACHINE_ID is required"
[[ -n "$PRL_WALLET" ]] || fail "PRL_WALLET is required"
[[ -x "$PYTHON_BIN" ]] || fail "python binary not executable: $PYTHON_BIN"
[[ -f "$WATCHER_SCRIPT" ]] || fail "watcher script not found: $WATCHER_SCRIPT"
[[ -x "$MINER_BIN" ]] || fail "miner binary not executable: $MINER_BIN"

if [[ -f "$GPU_TUNING_HELPER" ]] && [[ -n "$GPU_POWER_LIMIT$GPU_MEMORY_CLOCK$GPU_CORE_CLOCK" ]]; then
  if ! "$PYTHON_BIN" "$GPU_TUNING_HELPER" apply \
    --power-limit "$GPU_POWER_LIMIT" \
    --memory-clock "$GPU_MEMORY_CLOCK" \
    --core-clock "$GPU_CORE_CLOCK" \
    --state-dir "$STATE_DIR"; then
    printf '[vast-prl-launcher] gpu tuning apply reported an error; continuing without blocking watcher startup\n' >&2
  fi
fi

cmd=(
  "$PYTHON_BIN"
  "$WATCHER_SCRIPT"
  --machine-id "$MACHINE_ID"
  --miner-exec "$MINER_BIN"
  --miner-arg=--algorithm-gpu
  --miner-arg=pearlhash
  --miner-arg=--wallet
  --miner-arg="$PRL_WALLET"
  --miner-arg=--worker
  --miner-arg="$WORKER_NAME"
  --miner-arg=--pool
  --miner-arg="$POOL"
  --miner-arg=--password
  --miner-arg="$POOL_PASSWORD"
  --miner-arg=--disable-cpu
  --poll-seconds "$POLL_SECONDS"
  --min-idle-polls "$MIN_IDLE_POLLS"
  --min-busy-polls "$MIN_BUSY_POLLS"
  --reconcile-interval "$RECONCILE_INTERVAL"
  --stop-timeout-seconds "$STOP_TIMEOUT_SECONDS"
  --state-file "$STATE_DIR/state.json"
  --lock-file "$STATE_DIR/watcher.lock"
  --miner-log-file "$STATE_DIR/miner.log"
)

if [[ "$DRY_RUN" == "1" ]]; then
  cmd+=(--dry-run)
fi

exec "${cmd[@]}"
