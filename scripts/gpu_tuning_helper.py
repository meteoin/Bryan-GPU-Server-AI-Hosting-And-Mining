#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import time
from pathlib import Path
from typing import Any


MEMORY_CLOCK_PATTERN = re.compile(r"Memory\s*:\s*([0-9]+)\s*MHz", re.IGNORECASE)
GRAPHICS_CLOCK_PATTERN = re.compile(r"Graphics\s*:\s*([0-9]+)\s*MHz", re.IGNORECASE)


def run_command(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, capture_output=True, text=True)


def run_with_optional_sudo(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    direct = run_command(cmd)
    if direct.returncode == 0:
        return direct
    if cmd and cmd[0] == "sudo":
        return direct
    sudo_cmd = ["sudo", "-n", *cmd]
    sudo_result = run_command(sudo_cmd)
    return sudo_result if sudo_result.returncode == 0 else direct


def parse_float(value: str | None) -> float | None:
    if value is None:
        return None
    stripped = str(value).strip()
    if not stripped or stripped.upper() == "N/A" or "[Not Supported]" in stripped:
        return None
    try:
        return float(stripped)
    except ValueError:
        return None


def parse_int(value: str | None) -> int | None:
    number = parse_float(value)
    return None if number is None else int(round(number))


def query_gpu_rows() -> list[dict[str, str]]:
    queries = [
        [
            "nvidia-smi",
            "--query-gpu=index,name,power.limit,power.min_limit,power.max_limit,clocks.current.graphics,clocks.current.memory",
            "--format=csv,noheader,nounits",
        ],
        [
            "nvidia-smi",
            "--query-gpu=index,name,power.limit,clocks.current.graphics,clocks.current.memory",
            "--format=csv,noheader,nounits",
        ],
    ]
    columns_options = [
        ["index", "name", "power_limit", "power_min_limit", "power_max_limit", "graphics_clock", "memory_clock"],
        ["index", "name", "power_limit", "graphics_clock", "memory_clock"],
    ]
    for cmd, columns in zip(queries, columns_options, strict=True):
        result = run_command(cmd)
        if result.returncode != 0:
            continue
        rows: list[dict[str, str]] = []
        for line in result.stdout.splitlines():
            parts = [part.strip() for part in line.split(",")]
            if len(parts) != len(columns):
                continue
            row = dict(zip(columns, parts, strict=True))
            row.setdefault("power_min_limit", "")
            row.setdefault("power_max_limit", "")
            rows.append(row)
        if rows:
            return rows
    return []


def parse_supported_clocks(output: str, gpu_count: int) -> list[dict[str, Any]]:
    data = [
        {
            "memory_supported": None,
            "graphics_supported": None,
            "memory_values": set(),
            "graphics_values": set(),
        }
        for _ in range(gpu_count)
    ]
    if gpu_count == 0:
        return data

    gpu_index = -1
    in_supported_clocks = False
    saw_gpu_header = False
    for raw_line in output.splitlines():
        line = raw_line.rstrip()
        stripped = line.strip()
        if not stripped:
            continue
        if line.startswith("GPU "):
            gpu_index += 1
            saw_gpu_header = True
            in_supported_clocks = False
            continue
        if gpu_index < 0 or gpu_index >= gpu_count:
            continue
        if stripped == "Supported Clocks":
            in_supported_clocks = True
            if data[gpu_index]["memory_supported"] is None:
                data[gpu_index]["memory_supported"] = True
            if data[gpu_index]["graphics_supported"] is None:
                data[gpu_index]["graphics_supported"] = True
            continue
        if not in_supported_clocks:
            continue
        lowered = stripped.lower()
        if "not supported" in lowered or lowered == "n/a":
            data[gpu_index]["memory_supported"] = False
            data[gpu_index]["graphics_supported"] = False
            continue
        memory_match = MEMORY_CLOCK_PATTERN.match(stripped)
        if memory_match:
            data[gpu_index]["memory_values"].add(int(memory_match.group(1)))
            continue
        graphics_match = GRAPHICS_CLOCK_PATTERN.match(stripped)
        if graphics_match:
            data[gpu_index]["graphics_values"].add(int(graphics_match.group(1)))

    if not saw_gpu_header and gpu_count == 1:
        single = data[0]
        for raw_line in output.splitlines():
            stripped = raw_line.strip()
            memory_match = MEMORY_CLOCK_PATTERN.match(stripped)
            if memory_match:
                single["memory_supported"] = True
                single["memory_values"].add(int(memory_match.group(1)))
                continue
            graphics_match = GRAPHICS_CLOCK_PATTERN.match(stripped)
            if graphics_match:
                single["graphics_supported"] = True
                single["graphics_values"].add(int(graphics_match.group(1)))

    for item in data:
        if item["memory_supported"] is None:
            item["memory_supported"] = bool(item["memory_values"])
        if item["graphics_supported"] is None:
            item["graphics_supported"] = bool(item["graphics_values"])
        item["memory_values"] = sorted(item["memory_values"])
        item["graphics_values"] = sorted(item["graphics_values"])
    return data


def probe_gpus() -> dict[str, Any]:
    rows = query_gpu_rows()
    if not rows:
        return {
            "ok": False,
            "error": "Unable to query GPUs with nvidia-smi",
            "gpus": [],
            "generated_epoch": time.time(),
        }

    supported_clocks_result = run_command(["nvidia-smi", "-q", "-d", "SUPPORTED_CLOCKS"])
    clock_data = parse_supported_clocks(supported_clocks_result.stdout, len(rows)) if supported_clocks_result.returncode == 0 else [
        {
            "memory_supported": False,
            "graphics_supported": False,
            "memory_values": [],
            "graphics_values": [],
        }
        for _ in rows
    ]

    gpus: list[dict[str, Any]] = []
    for row, clocks in zip(rows, clock_data, strict=True):
        power_limit = parse_float(row.get("power_limit"))
        power_min = parse_float(row.get("power_min_limit"))
        power_max = parse_float(row.get("power_max_limit"))
        power_supported = power_limit is not None
        gpus.append(
            {
                "index": parse_int(row.get("index")) or 0,
                "name": row.get("name", "Unknown GPU"),
                "power_limit": {
                    "supported": power_supported,
                    "current": power_limit,
                    "min": power_min,
                    "max": power_max,
                },
                "memory_clock": {
                    "supported": bool(clocks["memory_supported"]),
                    "current": parse_int(row.get("memory_clock")),
                    "values": clocks["memory_values"],
                },
                "core_clock": {
                    "supported": bool(clocks["graphics_supported"]),
                    "current": parse_int(row.get("graphics_clock")),
                    "values": clocks["graphics_values"],
                },
            }
        )

    return {
        "ok": True,
        "error": "",
        "gpus": gpus,
        "generated_epoch": time.time(),
        "supported_clocks_command_ok": supported_clocks_result.returncode == 0,
    }


def trim_supported_values(values: list[int], limit: int = 6) -> list[int]:
    if len(values) <= limit:
        return values
    head = values[: limit // 2]
    tail = values[-(limit - len(head)) :]
    return [*head, *tail]


def apply_power_limit(gpu: dict[str, Any], requested: float) -> dict[str, Any]:
    capability = gpu["power_limit"]
    minimum = capability.get("min")
    maximum = capability.get("max")
    if not capability.get("supported"):
        return {"setting": "power_limit", "gpu_index": gpu["index"], "status": "skipped", "message": "power limit not supported"}
    if minimum is not None and requested < float(minimum):
        return {
            "setting": "power_limit",
            "gpu_index": gpu["index"],
            "status": "skipped",
            "message": f"requested {requested:g}W below minimum {minimum:g}W",
        }
    if maximum is not None and requested > float(maximum):
        return {
            "setting": "power_limit",
            "gpu_index": gpu["index"],
            "status": "skipped",
            "message": f"requested {requested:g}W above maximum {maximum:g}W",
        }
    result = run_with_optional_sudo(["nvidia-smi", "-i", str(gpu["index"]), "-pl", f"{requested:g}"])
    if result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip() or "nvidia-smi -pl failed"
        return {"setting": "power_limit", "gpu_index": gpu["index"], "status": "error", "message": message}
    return {
        "setting": "power_limit",
        "gpu_index": gpu["index"],
        "status": "applied",
        "message": f"set to {requested:g}W",
    }


def apply_clock_lock(gpu: dict[str, Any], requested: int, setting_name: str, switch: str) -> dict[str, Any]:
    capability = gpu[setting_name]
    if not capability.get("supported"):
        return {"setting": setting_name, "gpu_index": gpu["index"], "status": "skipped", "message": f"{setting_name} not supported"}
    supported_values = capability.get("values") or []
    if supported_values and requested not in supported_values:
        preview = ", ".join(str(value) for value in trim_supported_values(supported_values))
        return {
            "setting": setting_name,
            "gpu_index": gpu["index"],
            "status": "skipped",
            "message": f"{requested} MHz unsupported; available values include {preview}",
        }
    result = run_with_optional_sudo(["nvidia-smi", "-i", str(gpu["index"]), switch, str(requested)])
    if result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip() or f"nvidia-smi {switch} failed"
        return {"setting": setting_name, "gpu_index": gpu["index"], "status": "error", "message": message}
    return {
        "setting": setting_name,
        "gpu_index": gpu["index"],
        "status": "applied",
        "message": f"locked to {requested} MHz",
    }


def maybe_write_state_file(state_file: Path | None, payload: dict[str, Any]) -> None:
    if state_file is None:
        return
    state_file.parent.mkdir(parents=True, exist_ok=True)
    state_file.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def build_state_file_path(args: argparse.Namespace) -> Path | None:
    if args.state_file:
        return Path(args.state_file).expanduser()
    if args.state_dir:
        return Path(args.state_dir).expanduser() / "gpu_tuning_state.json"
    return None


def action_probe(args: argparse.Namespace) -> int:
    payload = {
        "mode": "probe",
        "probe": probe_gpus(),
        "requested": {
            "power_limit": args.power_limit,
            "memory_clock": args.memory_clock,
            "core_clock": args.core_clock,
        },
        "generated_epoch": time.time(),
    }
    maybe_write_state_file(build_state_file_path(args), payload)
    print(json.dumps(payload))
    return 0 if payload["probe"]["ok"] else 1


def action_apply(args: argparse.Namespace) -> int:
    probe = probe_gpus()
    results: list[dict[str, Any]] = []
    requested: dict[str, Any] = {
        "power_limit": args.power_limit,
        "memory_clock": args.memory_clock,
        "core_clock": args.core_clock,
    }
    if not probe["ok"]:
        payload = {
            "mode": "apply",
            "ok": False,
            "message": probe["error"],
            "probe": probe,
            "results": results,
            "requested": requested,
            "generated_epoch": time.time(),
        }
        maybe_write_state_file(build_state_file_path(args), payload)
        print(json.dumps(payload))
        return 1

    power_limit = parse_float(args.power_limit) if args.power_limit else None
    memory_clock = parse_int(args.memory_clock) if args.memory_clock else None
    core_clock = parse_int(args.core_clock) if args.core_clock else None

    if power_limit is None and memory_clock is None and core_clock is None:
        payload = {
            "mode": "apply",
            "ok": True,
            "message": "No GPU tuning values requested",
            "probe": probe,
            "results": [],
            "requested": requested,
            "generated_epoch": time.time(),
        }
        maybe_write_state_file(build_state_file_path(args), payload)
        print(json.dumps(payload))
        return 0

    for gpu in probe["gpus"]:
        if power_limit is not None:
            results.append(apply_power_limit(gpu, power_limit))
        if memory_clock is not None:
            results.append(apply_clock_lock(gpu, memory_clock, "memory_clock", "-lmc"))
        if core_clock is not None:
            results.append(apply_clock_lock(gpu, core_clock, "core_clock", "-lgc"))

    statuses = {result["status"] for result in results}
    ok = "error" not in statuses
    if "applied" in statuses and "error" not in statuses:
        message = "Applied supported GPU tuning values"
    elif "skipped" in statuses and "applied" not in statuses and "error" not in statuses:
        message = "Skipped unsupported GPU tuning values"
    else:
        message = "Applied GPU tuning with some errors" if results else "No GPU tuning actions ran"

    payload = {
        "mode": "apply",
        "ok": ok,
        "message": message,
        "probe": probe,
        "results": results,
        "requested": requested,
        "generated_epoch": time.time(),
    }
    maybe_write_state_file(build_state_file_path(args), payload)
    print(json.dumps(payload))
    return 0 if ok else 1


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Probe and safely apply NVIDIA GPU tuning.")
    parser.add_argument("mode", choices=["probe", "apply"], help="Probe GPU tuning support or apply requested settings")
    parser.add_argument("--power-limit", default=os.environ.get("GPU_POWER_LIMIT", ""), help="Requested GPU power limit in watts")
    parser.add_argument("--memory-clock", default=os.environ.get("GPU_MEMORY_CLOCK", ""), help="Requested locked memory clock in MHz")
    parser.add_argument("--core-clock", default=os.environ.get("GPU_CORE_CLOCK", ""), help="Requested locked graphics clock in MHz")
    parser.add_argument("--state-dir", default=os.environ.get("STATE_DIR", ""), help="Directory for gpu_tuning_state.json")
    parser.add_argument("--state-file", default="", help="Explicit state file path")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.mode == "probe":
        return action_probe(args)
    return action_apply(args)


if __name__ == "__main__":
    raise SystemExit(main())
