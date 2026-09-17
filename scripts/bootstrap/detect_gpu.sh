#!/usr/bin/env bash
# Detect NVIDIA GPUs and classify CMP 170HX vs other cards.
set -Eeuo pipefail

BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${BOOTSTRAP_DIR}/common.sh"
bryan_init_paths

detect_gpu_lines() {
  if command -v lspci >/dev/null 2>&1; then
    lspci -nn 2>/dev/null | grep -Ei 'NVIDIA|3D|VGA' || true
    return 0
  fi
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || true
    return 0
  fi
  printf ''
}

summarize_detected_gpus() {
  local lines="$1"
  local hx_count other_count
  hx_count="$(printf '%s\n' "${lines}" | grep -ci 'CMP 170HX' || true)"
  other_count="$(printf '%s\n' "${lines}" | grep -ci 'NVIDIA' || true)"
  if [[ "${hx_count}" -gt 0 ]]; then
    other_count="$((other_count - hx_count))"
    if [[ "${other_count}" -lt 0 ]]; then
      other_count=0
    fi
  fi

  DETECTED_170HX="${hx_count}"
  DETECTED_OTHER_NVIDIA="${other_count}"
  DETECTED_NVIDIA="$((hx_count + other_count))"
  if [[ "${hx_count}" -gt 0 && "${other_count}" -eq 0 ]]; then
    DETECTED_SUMMARY="${hx_count}x NVIDIA CMP 170HX"
    DETECTED_KIND="170hx"
    RECOMMENDED_PROFILE="170hx-host"
  elif [[ "${hx_count}" -gt 0 ]]; then
    DETECTED_SUMMARY="${hx_count}x NVIDIA CMP 170HX, ${other_count}x other NVIDIA"
    DETECTED_KIND="mixed"
    RECOMMENDED_PROFILE="170hx-host"
  elif [[ "${other_count}" -gt 0 ]]; then
    local names
    names="$(printf '%s\n' "${lines}" | grep -i NVIDIA | sed -E 's/^[^:]+: //; s/ \\[.*//' | head -n 3 | paste -sd ', ' -)"
    if [[ -z "${names}" ]]; then
      names="NVIDIA GPU"
    fi
    DETECTED_SUMMARY="${other_count}x ${names}"
    DETECTED_KIND="other"
    RECOMMENDED_PROFILE="miner-only"
  else
    DETECTED_SUMMARY="No NVIDIA GPU detected"
    DETECTED_KIND="none"
    RECOMMENDED_PROFILE=""
  fi
}

GPU_LINES="$(detect_gpu_lines)"
summarize_detected_gpus "${GPU_LINES}"

if [[ "${1:-}" == "--print" ]]; then
  printf 'kind=%s\n' "${DETECTED_KIND}"
  printf 'summary=%s\n' "${DETECTED_SUMMARY}"
  printf 'count_170hx=%s\n' "${DETECTED_170HX}"
  printf 'count_other=%s\n' "${DETECTED_OTHER_NVIDIA}"
  printf 'recommended_profile=%s\n' "${RECOMMENDED_PROFILE}"
fi
