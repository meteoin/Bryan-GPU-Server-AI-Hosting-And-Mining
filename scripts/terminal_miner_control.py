#!/usr/bin/env python3
from __future__ import annotations

import argparse
import curses
import json
import os
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


FIELD_ORDER = [
    "MACHINE_ID",
    "MINER_BIN",
    "PRL_WALLET",
    "WORKER_NAME",
    "POOL",
    "POOL_PASSWORD",
    "GPU_POWER_LIMIT",
    "GPU_MEMORY_CLOCK",
    "GPU_CORE_CLOCK",
    "POLL_SECONDS",
    "MIN_IDLE_POLLS",
    "MIN_BUSY_POLLS",
    "RECONCILE_INTERVAL",
    "STOP_TIMEOUT_SECONDS",
    "DRY_RUN",
]

FIELD_LABELS = {
    "MACHINE_ID": "Machine ID",
    "MINER_BIN": "Miner Binary",
    "PRL_WALLET": "Wallet",
    "WORKER_NAME": "Worker",
    "POOL": "Pool",
    "POOL_PASSWORD": "Pool Password",
    "GPU_POWER_LIMIT": "GPU PL",
    "GPU_MEMORY_CLOCK": "GPU MCLK",
    "GPU_CORE_CLOCK": "GPU CCLK",
    "POLL_SECONDS": "Poll Seconds",
    "MIN_IDLE_POLLS": "Min Idle Polls",
    "MIN_BUSY_POLLS": "Min Busy Polls",
    "RECONCILE_INTERVAL": "Reconcile Sec",
    "STOP_TIMEOUT_SECONDS": "Stop Timeout",
    "DRY_RUN": "Dry Run",
}

HASHRATE_PATTERN = re.compile(r"Hashrate\s+([0-9.]+\s+[A-Za-z/]+)")
SHARE_PATTERN = re.compile(r"Share stats \[([0-9.]+)% / ([0-9.]+)%\]")
ANSI_ESCAPE_PATTERN = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
CARET_ESCAPE_PATTERN = re.compile(r"\^\[\[[0-9;?]*[A-Za-z]")


def load_env_file(path: Path) -> tuple[list[str], dict[str, str]]:
    lines: list[str] = []
    values: dict[str, str] = {}
    if not path.exists():
        return lines, values
    for raw_line in path.read_text().splitlines():
        lines.append(raw_line)
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#") or "=" not in raw_line:
            continue
        key, value = raw_line.split("=", 1)
        values[key.strip()] = value.strip()
    return lines, values


def write_env_file(path: Path, original_lines: list[str], values: dict[str, str]) -> None:
    emitted_keys: set[str] = set()
    output_lines: list[str] = []
    for raw_line in original_lines:
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#") or "=" not in raw_line:
            output_lines.append(raw_line)
            continue
        key, _ = raw_line.split("=", 1)
        key = key.strip()
        if key in values:
            output_lines.append(f"{key}={values[key]}")
            emitted_keys.add(key)
        else:
            output_lines.append(raw_line)
    for key in FIELD_ORDER:
        if key in values and key not in emitted_keys:
            output_lines.append(f"{key}={values[key]}")
            emitted_keys.add(key)
    for key in sorted(values):
        if key not in emitted_keys:
            output_lines.append(f"{key}={values[key]}")
    tmp_path = path.with_suffix(path.suffix + ".tmp")
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path.write_text("\n".join(output_lines) + "\n")
    tmp_path.replace(path)


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


def read_json_file(path: Path) -> dict[str, Any]:
    try:
        import json

        return json.loads(path.read_text()) if path.exists() else {}
    except Exception:
        return {}


def tail_lines(path: Path, limit: int) -> list[str]:
    if not path.exists():
        return []
    lines = [strip_ansi(line) for line in path.read_text(errors="replace").splitlines()]
    return lines[-limit:]


def strip_ansi(value: str) -> str:
    cleaned = ANSI_ESCAPE_PATTERN.sub("", value)
    return CARET_ESCAPE_PATTERN.sub("", cleaned)


def derive_state_dir(config: dict[str, str]) -> Path:
    explicit = config.get("STATE_DIR", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    machine_id = config.get("MACHINE_ID", "").strip() or "unknown"
    xdg_state_home = os.environ.get("XDG_STATE_HOME")
    if xdg_state_home:
        base = Path(xdg_state_home)
    else:
        base = Path.home() / ".local" / "state"
    return base / "vast-host-miner" / machine_id


def get_gpu_stats() -> list[dict[str, str]]:
    cmd = [
        "nvidia-smi",
        "--query-gpu=index,name,temperature.gpu,power.draw,power.limit,clocks.current.graphics,clocks.current.memory,utilization.gpu,memory.used,memory.total",
        "--format=csv,noheader,nounits",
    ]
    result = run_command(cmd)
    if result.returncode != 0:
        return [{"error": result.stderr.strip() or result.stdout.strip() or "nvidia-smi failed"}]
    rows: list[dict[str, str]] = []
    columns = [
        "index",
        "name",
        "temp",
        "power_draw",
        "power_limit",
        "graphics_clock",
        "memory_clock",
        "gpu_util",
        "memory_used",
        "memory_total",
    ]
    for line in result.stdout.splitlines():
        values = [part.strip() for part in line.split(",")]
        if len(values) != len(columns):
            continue
        rows.append(dict(zip(columns, values, strict=True)))
    return rows or [{"error": "No GPUs detected"}]


def get_service_status(service_name: str) -> dict[str, str]:
    active = run_command(["systemctl", "is-active", service_name])
    enabled = run_command(["systemctl", "is-enabled", service_name])
    return {
        "active": active.stdout.strip() or active.stderr.strip() or "unknown",
        "enabled": enabled.stdout.strip() or enabled.stderr.strip() or "unknown",
    }


def run_json_command(cmd: list[str]) -> dict[str, Any]:
    result = run_with_optional_sudo(cmd)
    if result.returncode != 0 and not result.stdout.strip():
        return {"ok": False, "message": result.stderr.strip() or "command failed"}
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return {
            "ok": False,
            "message": result.stderr.strip() or result.stdout.strip() or "invalid JSON output",
        }


def extract_hashrate(log_lines: list[str]) -> str:
    for line in reversed(log_lines):
        match = HASHRATE_PATTERN.search(line)
        if match:
            return match.group(1)
    return "n/a"


def extract_share_stats(log_lines: list[str]) -> str:
    for line in reversed(log_lines):
        match = SHARE_PATTERN.search(line)
        if match:
            return f"{match.group(1)}% accepted / {match.group(2)}% rejected"
    return "n/a"


def parse_hashrate_ths(hashrate: str) -> float | None:
    parts = hashrate.split()
    if len(parts) != 2:
        return None
    try:
        value = float(parts[0])
    except ValueError:
        return None
    unit = parts[1].lower()
    multipliers = {
        "h/s": 1e-12,
        "kh/s": 1e-9,
        "mh/s": 1e-6,
        "gh/s": 1e-3,
        "th/s": 1.0,
        "ph/s": 1e3,
    }
    return value * multipliers.get(unit, 0) if unit in multipliers else None


def format_value(value: str, max_len: int) -> str:
    if len(value) <= max_len:
        return value
    if max_len <= 3:
        return value[:max_len]
    return value[: max_len - 3] + "..."


def init_colors() -> dict[str, int]:
    colors = {
        "default": curses.A_NORMAL,
        "title": curses.A_BOLD,
        "header_good": curses.A_BOLD,
        "header_warn": curses.A_BOLD,
        "header_bad": curses.A_BOLD,
        "selected": curses.A_REVERSE | curses.A_BOLD,
        "message": curses.A_DIM,
        "good": curses.A_BOLD,
        "warn": curses.A_BOLD,
        "bad": curses.A_BOLD,
        "dim": curses.A_DIM,
        "accent": curses.A_BOLD,
        "status_bar": curses.A_REVERSE | curses.A_BOLD,
        "badge": curses.A_BOLD,
        "log_good": curses.A_NORMAL,
        "log_warn": curses.A_NORMAL,
        "log_bad": curses.A_NORMAL,
        "log_info": curses.A_NORMAL,
        "banner_good": curses.A_REVERSE | curses.A_BOLD,
        "banner_warn": curses.A_REVERSE | curses.A_BOLD,
        "banner_bad": curses.A_REVERSE | curses.A_BOLD,
    }
    if not curses.has_colors():
        return colors
    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(1, curses.COLOR_CYAN, -1)
    curses.init_pair(2, curses.COLOR_GREEN, -1)
    curses.init_pair(3, curses.COLOR_YELLOW, -1)
    curses.init_pair(4, curses.COLOR_RED, -1)
    curses.init_pair(5, curses.COLOR_BLACK, curses.COLOR_CYAN)
    curses.init_pair(6, curses.COLOR_MAGENTA, -1)
    curses.init_pair(7, curses.COLOR_BLUE, -1)
    curses.init_pair(8, curses.COLOR_BLACK, curses.COLOR_GREEN)
    curses.init_pair(9, curses.COLOR_BLACK, curses.COLOR_YELLOW)
    curses.init_pair(10, curses.COLOR_WHITE, curses.COLOR_RED)
    colors.update(
        {
            "title": curses.color_pair(1) | curses.A_BOLD,
            "header_good": curses.color_pair(2) | curses.A_BOLD,
            "header_warn": curses.color_pair(3) | curses.A_BOLD,
            "header_bad": curses.color_pair(4) | curses.A_BOLD,
            "selected": curses.color_pair(5) | curses.A_BOLD,
            "message": curses.color_pair(6),
            "good": curses.color_pair(2) | curses.A_BOLD,
            "warn": curses.color_pair(3) | curses.A_BOLD,
            "bad": curses.color_pair(4) | curses.A_BOLD,
            "dim": curses.color_pair(7),
            "accent": curses.color_pair(1),
            "status_bar": curses.color_pair(7) | curses.A_BOLD,
            "badge": curses.color_pair(6) | curses.A_BOLD,
            "log_good": curses.color_pair(2),
            "log_warn": curses.color_pair(3),
            "log_bad": curses.color_pair(4),
            "log_info": curses.color_pair(7),
            "banner_good": curses.color_pair(8) | curses.A_BOLD,
            "banner_warn": curses.color_pair(9) | curses.A_BOLD,
            "banner_bad": curses.color_pair(10) | curses.A_BOLD,
        }
    )
    return colors


def state_attr(colors: dict[str, int], value: str) -> int:
    lowered = value.strip().lower()
    if lowered in {"active", "running", "idle", "enabled"}:
        return colors["good"]
    if lowered in {"unknown", "activating", "deactivating", "hold"}:
        return colors["warn"]
    if lowered in {"inactive", "failed", "busy", "disabled", "stopped"}:
        return colors["bad"]
    return colors["accent"]


def log_attr(colors: dict[str, int], line: str) -> int:
    lowered = line.lower()
    if "accepted" in lowered or "started miner" in lowered:
        return colors["log_good"]
    if "error" in lowered or "failed" in lowered or "rejected" in lowered or "sigkill" in lowered:
        return colors["log_bad"]
    if "hashrate" in lowered or "job received" in lowered or "stopping miner" in lowered:
        return colors["log_warn"]
    return colors["log_info"]


def numeric_attr(colors: dict[str, int], value: float, warn_at: float, bad_at: float) -> int:
    if value >= bad_at:
        return colors["bad"]
    if value >= warn_at:
        return colors["warn"]
    return colors["good"]


def make_bar(value: float, maximum: float, width: int) -> str:
    if width <= 2:
        return ""
    ratio = 0.0 if maximum <= 0 else max(0.0, min(1.0, value / maximum))
    filled = int(round(ratio * width))
    return "[" + ("#" * filled).ljust(width, "-") + "]"


def make_sparkline(values: list[float], width: int) -> str:
    if width <= 0:
        return ""
    if not values:
        return "-" * width
    ticks = " .:-=+*#%@"
    window = values[-width:]
    low = min(window)
    high = max(window)
    if high <= low:
        return ticks[-2] * len(window)
    chars = []
    for value in window:
        ratio = (value - low) / (high - low)
        index = min(len(ticks) - 1, max(0, int(round(ratio * (len(ticks) - 1)))))
        chars.append(ticks[index])
    return "".join(chars)


def summarize_capability(gpu_tuning_state: dict[str, Any]) -> str:
    requested = gpu_tuning_state.get("requested", {})
    if not any(str(requested.get(key, "")).strip() for key in ("power_limit", "memory_clock", "core_clock")):
        return "defaults"
    probe = gpu_tuning_state.get("probe", gpu_tuning_state)
    gpus = probe.get("gpus", [])
    if not gpus:
        return "GPU tuning probe unavailable"
    gpu = gpus[0]
    parts: list[str] = []
    power = gpu.get("power_limit", {})
    if power.get("supported"):
        minimum = power.get("min")
        maximum = power.get("max")
        if minimum is not None and maximum is not None:
            parts.append(f"PL {minimum:g}-{maximum:g}W")
        else:
            parts.append("PL supported")
    else:
        parts.append("PL unsupported")
    memory = gpu.get("memory_clock", {})
    if memory.get("supported"):
        values = memory.get("values") or []
        preview = ",".join(str(value) for value in trim_values(values))
        parts.append(f"MCLK yes [{preview}]")
    else:
        parts.append("MCLK no")
    core = gpu.get("core_clock", {})
    if core.get("supported"):
        values = core.get("values") or []
        preview = ",".join(str(value) for value in trim_values(values))
        parts.append(f"CCLK yes [{preview}]")
    else:
        parts.append("CCLK no")
    return " | ".join(parts)


def trim_values(values: list[int], limit: int = 4) -> list[int]:
    if len(values) <= limit:
        return values
    return [values[0], values[1], values[-2], values[-1]]


def summarize_reason(reasons: list[Any], max_items: int = 2) -> str:
    cleaned = [str(reason).strip() for reason in reasons if str(reason).strip()]
    if not cleaned:
        return "n/a"
    return " | ".join(cleaned[:max_items])


def banner_for_state(observed_state: str, miner_status: str, reasons: list[Any]) -> tuple[str, str]:
    lowered_state = observed_state.strip().lower()
    lowered_miner = miner_status.strip().lower()
    reason_text = summarize_reason(reasons, max_items=1)
    if lowered_state == "busy":
        return ("banner_bad", f" VAST OCCUPIED — mining paused for renter ({reason_text}) ")
    if lowered_state == "idle" and lowered_miner == "running":
        return ("banner_good", f" HOST IDLE — mining active ({reason_text}) ")
    if lowered_state == "idle":
        return ("banner_warn", f" HOST IDLE — watcher is waiting to start miner ({reason_text}) ")
    return ("banner_warn", f" WATCHER UNCERTAIN — holding current state ({reason_text}) ")


class MinerControlApp:
    def __init__(self, env_file: Path, service_name: str) -> None:
        self.env_file = env_file
        self.service_name = service_name
        self.original_lines, self.config = load_env_file(env_file)
        for key in FIELD_ORDER:
            self.config.setdefault(key, "")
        self.selected_index = 0
        self.message = ""
        self.last_refresh = 0.0
        self.state_dir = derive_state_dir(self.config)
        self.state_file = self.state_dir / "state.json"
        self.log_file = self.state_dir / "miner.log"
        self.service_status: dict[str, str] = {}
        self.watcher_state: dict[str, Any] = {}
        self.gpu_stats: list[dict[str, str]] = []
        self.log_lines: list[str] = []
        self.colors: dict[str, int] = {}
        self.hashrate_history: list[float] = []
        self.temp_history: list[float] = []
        self.util_history: list[float] = []
        self.python_bin = sys.executable or "/usr/bin/python3"
        self.gpu_tuning_helper = Path(__file__).with_name("gpu_tuning_helper.py")
        self.gpu_tuning_state: dict[str, Any] = {}
        self.last_tuning_refresh = 0.0

    def refresh(self) -> None:
        self.state_dir = derive_state_dir(self.config)
        self.state_file = self.state_dir / "state.json"
        self.log_file = self.state_dir / "miner.log"
        self.service_status = get_service_status(self.service_name)
        self.watcher_state = read_json_file(self.state_file)
        self.gpu_stats = get_gpu_stats()
        self.log_lines = tail_lines(self.log_file, 40)
        if time.time() - self.last_tuning_refresh >= 30 or not self.gpu_tuning_state:
            self.refresh_tuning_state()
        current_hashrate = parse_hashrate_ths(extract_hashrate(self.log_lines))
        if current_hashrate is not None:
            self.hashrate_history = (self.hashrate_history + [current_hashrate])[-60:]
        if self.gpu_stats and "error" not in self.gpu_stats[0]:
            try:
                self.temp_history = (
                    self.temp_history + [max(float(gpu["temp"]) for gpu in self.gpu_stats)]
                )[-60:]
            except Exception:
                pass
            try:
                util_values = [float(gpu["gpu_util"]) for gpu in self.gpu_stats]
                existing = self.util_history if isinstance(self.util_history, list) else []
                self.util_history = (existing + [max(util_values)])[-60:]
            except Exception:
                pass
        self.last_refresh = time.time()

    def refresh_tuning_state(self) -> None:
        if not self.gpu_tuning_helper.exists():
            self.gpu_tuning_state = {"ok": False, "message": f"missing helper: {self.gpu_tuning_helper}"}
            self.last_tuning_refresh = time.time()
            return
        payload = run_json_command(
            [
                self.python_bin,
                str(self.gpu_tuning_helper),
                "probe",
                "--state-dir",
                str(self.state_dir),
                "--power-limit",
                self.config.get("GPU_POWER_LIMIT", ""),
                "--memory-clock",
                self.config.get("GPU_MEMORY_CLOCK", ""),
                "--core-clock",
                self.config.get("GPU_CORE_CLOCK", ""),
            ]
        )
        self.gpu_tuning_state = payload
        self.last_tuning_refresh = time.time()

    def save(self) -> None:
        write_env_file(self.env_file, self.original_lines, self.config)
        self.original_lines, self.config = load_env_file(self.env_file)
        for key in FIELD_ORDER:
            self.config.setdefault(key, "")
        self.message = f"Saved {self.env_file}"

    def run_service_action(self, action: str) -> None:
        result = run_with_optional_sudo(["systemctl", action, self.service_name])
        if result.returncode == 0:
            self.message = f"Service {action} succeeded"
            self.refresh()
            return
        stderr = result.stderr.strip() or result.stdout.strip() or "unknown error"
        self.message = f"Service {action} failed: {stderr}"

    def apply_gpu_tuning(self) -> None:
        pl = self.config.get("GPU_POWER_LIMIT", "").strip()
        mclk = self.config.get("GPU_MEMORY_CLOCK", "").strip()
        cclk = self.config.get("GPU_CORE_CLOCK", "").strip()
        if not self.gpu_tuning_helper.exists():
            self.message = f"GPU tuning helper missing: {self.gpu_tuning_helper}"
            return
        if not any([pl, mclk, cclk]):
            self.message = "No GPU tuning values set"
            return
        payload = run_json_command(
            [
                self.python_bin,
                str(self.gpu_tuning_helper),
                "apply",
                "--state-dir",
                str(self.state_dir),
                "--power-limit",
                pl,
                "--memory-clock",
                mclk,
                "--core-clock",
                cclk,
            ]
        )
        self.gpu_tuning_state = payload
        self.last_tuning_refresh = time.time()
        self.refresh()
        results = payload.get("results", [])
        problems = [item for item in results if item.get("status") in {"error", "skipped"}]
        if not payload.get("ok", False):
            self.message = "GPU tuning failed: " + payload.get("message", "unknown error")
        elif problems:
            summary = " | ".join(
                f"GPU{item.get('gpu_index')} {item.get('setting')}: {item.get('message')}" for item in problems[:2]
            )
            self.message = payload.get("message", "GPU tuning completed") + f" ({summary})"
        else:
            self.message = payload.get("message", "GPU tuning applied")

    def edit_selected_field(self, stdscr: Any) -> None:
        key = FIELD_ORDER[self.selected_index]
        current = self.config.get(key, "")
        height, width = stdscr.getmaxyx()
        prompt = f"{FIELD_LABELS.get(key, key)}: "
        curses.echo()
        curses.curs_set(1)
        stdscr.move(height - 1, 0)
        stdscr.clrtoeol()
        stdscr.addnstr(height - 1, 0, prompt, width - 1)
        stdscr.addnstr(height - 1, len(prompt), current, max(0, width - len(prompt) - 1))
        stdscr.refresh()
        try:
            new_value = stdscr.getstr(height - 1, len(prompt), max(1, width - len(prompt) - 1))
            self.config[key] = new_value.decode(errors="replace").strip()
            self.message = f"Updated {FIELD_LABELS.get(key, key)}"
        finally:
            curses.noecho()
            curses.curs_set(0)

    def draw_box(self, win: Any, title: str) -> None:
        win.box()
        max_y, max_x = win.getmaxyx()
        if max_x > len(title) + 4:
            win.addnstr(0, 2, f" {title} ", max_x - 4, self.colors["title"])

    def add_colored_chunks(self, win: Any, row: int, chunks: list[tuple[str, int]], max_width: int) -> None:
        col = 0
        for text, attr in chunks:
            if col >= max_width:
                break
            safe = text[: max_width - col]
            win.addnstr(row, col, safe, max_width - col, attr)
            col += len(safe)

    def gpu_line_attr(self, gpu: dict[str, str]) -> int:
        try:
            temp = float(gpu["temp"])
        except Exception:
            temp = 0
        try:
            util = float(gpu["gpu_util"])
        except Exception:
            util = 0
        if temp >= 82 or util >= 98:
            return self.colors["warn"]
        if temp >= 75:
            return self.colors["accent"]
        return self.colors["good"]

    def draw_badge(self, win: Any, row: int, col: int, label: str, value: str, attr: int) -> int:
        text = f" {label}: {value} "
        win.addnstr(row, col, text, len(text), attr)
        return col + len(text) + 1

    def draw(self, stdscr: Any) -> None:
        stdscr.erase()
        height, width = stdscr.getmaxyx()
        if height < 24 or width < 100:
            stdscr.addstr(0, 0, "Terminal too small. Resize to at least 100x24.")
            stdscr.refresh()
            return

        service_value = self.service_status.get("active", "unknown")
        enabled_value = self.service_status.get("enabled", "unknown")
        watcher_value = str(self.watcher_state.get("observed_state", "n/a"))
        miner_value = str(self.watcher_state.get("miner_status", "n/a"))
        reasons = self.watcher_state.get("observed_reasons", [])
        banner_color_key, banner_text = banner_for_state(watcher_value, miner_value, reasons)
        subtitle = "Keys: Up/Down select | Enter edit | s save | r restart | x start | z stop | a apply GPU | g refresh | q quit"
        stdscr.addnstr(0, 0, " " * (width - 1), width - 1, self.colors["status_bar"])
        self.add_colored_chunks(
            stdscr,
            0,
            [
                (" Service ", self.colors["status_bar"]),
                (service_value, state_attr(self.colors, service_value)),
                ("   Enabled ", self.colors["status_bar"]),
                (enabled_value, state_attr(self.colors, enabled_value)),
                ("   Watcher ", self.colors["status_bar"]),
                (watcher_value, state_attr(self.colors, watcher_value)),
            ],
            width - 1,
        )
        stdscr.addnstr(1, 0, subtitle, width - 1, self.colors["accent"])
        stdscr.addnstr(2, 0, " " * (width - 1), width - 1, self.colors[banner_color_key])
        stdscr.addnstr(2, 0, format_value(banner_text, width - 1), width - 1, self.colors[banner_color_key])
        stdscr.addnstr(3, 0, self.message, width - 1, self.colors["message"])

        top = 4
        form_width = max(40, width // 3)
        metrics_height = max(10, height // 3)
        log_height = height - top - metrics_height - 1
        form_win = stdscr.derwin(height - top - 1, form_width, top, 0)
        metrics_win = stdscr.derwin(metrics_height, width - form_width, top, form_width)
        log_win = stdscr.derwin(log_height, width - form_width, top + metrics_height, form_width)

        self.draw_box(form_win, "Config")
        self.draw_box(metrics_win, "Status")
        self.draw_box(log_win, "Miner Log")

        visible_fields = height - top - 3
        scroll_offset = 0
        if self.selected_index >= visible_fields:
            scroll_offset = self.selected_index - visible_fields + 1
        for row, key in enumerate(FIELD_ORDER[scroll_offset : scroll_offset + visible_fields]):
            actual_index = scroll_offset + row
            label = FIELD_LABELS.get(key, key)
            value = self.config.get(key, "")
            attr = self.colors["selected"] if actual_index == self.selected_index else self.colors["default"]
            display = f"{label:<14} {format_value(value, form_width - 18)}"
            form_win.addnstr(row + 1, 1, display, form_width - 2, attr)

        metrics_row = 1
        hashrate_text = extract_hashrate(self.log_lines)
        metrics = [
            f"Machine: {self.config.get('MACHINE_ID', 'n/a')}",
            f"Watcher State: {watcher_value}",
            f"Miner Status: {self.watcher_state.get('miner_status', 'n/a')}",
            f"Last Action: {self.watcher_state.get('last_action', 'n/a')}",
            f"Observed Count: {self.watcher_state.get('observed_count', 'n/a')}",
            f"Reason: {summarize_reason(reasons)}",
            f"GPU Tuning: {summarize_capability(self.gpu_tuning_state)}",
            f"Log File: {self.log_file}",
        ]
        badge_col = 1
        badge_col = self.draw_badge(
            metrics_win,
            metrics_row,
            badge_col,
            "Hashrate",
            hashrate_text,
            self.colors["badge"],
        )
        shares_text = extract_share_stats(self.log_lines)
        self.draw_badge(
            metrics_win,
            metrics_row,
            badge_col,
            "Shares",
            shares_text,
            self.colors["badge"],
        )
        metrics_row += 1
        for line in metrics:
            if metrics_row < metrics_height - 1:
                metrics_win.addnstr(metrics_row, 1, format_value(line, width - form_width - 3), width - form_width - 3, self.colors["default"])
                metrics_row += 1

        if self.gpu_stats:
            first = self.gpu_stats[0]
            if "error" in first:
                metrics_win.addnstr(metrics_row, 1, format_value(f"GPU: {first['error']}", width - form_width - 3), width - form_width - 3, self.colors["bad"])
                metrics_row += 1
            else:
                for gpu in self.gpu_stats:
                    try:
                        temp = float(gpu["temp"])
                    except Exception:
                        temp = 0.0
                    try:
                        power_draw = float(gpu["power_draw"])
                        power_limit = max(float(gpu["power_limit"]), 1.0)
                    except Exception:
                        power_draw = 0.0
                        power_limit = 1.0
                    try:
                        gpu_util = float(gpu["gpu_util"])
                    except Exception:
                        gpu_util = 0.0
                    line = (
                        f"GPU{gpu['index']} {gpu['name']} | {gpu['temp']}C {make_bar(temp, 95, 8)} | "
                        f"{gpu['power_draw']}/{gpu['power_limit']}W {make_bar(power_draw, power_limit, 8)} | "
                        f"GPU {gpu['gpu_util']}% {make_bar(gpu_util, 100, 8)} | "
                        f"MEM {gpu['memory_used']}/{gpu['memory_total']} MiB | "
                        f"CCLK {gpu['graphics_clock']} | MCLK {gpu['memory_clock']}"
                    )
                    if metrics_row < metrics_height - 1:
                        metrics_win.addnstr(
                            metrics_row,
                            1,
                            format_value(line, width - form_width - 3),
                            width - form_width - 3,
                            self.gpu_line_attr(gpu),
                        )
                        metrics_row += 1
        if metrics_row < metrics_height - 1:
            metrics_win.addnstr(
                metrics_row,
                1,
                format_value(f"Temp Trend: {make_sparkline(self.temp_history, 24)}", width - form_width - 3),
                width - form_width - 3,
                self.colors["accent"],
            )
            metrics_row += 1
        if metrics_row < metrics_height - 1:
            util_history = self.util_history if isinstance(self.util_history, list) else []
            metrics_win.addnstr(
                metrics_row,
                1,
                format_value(f"Util Trend: {make_sparkline(util_history, 24)}", width - form_width - 3),
                width - form_width - 3,
                self.colors["warn"],
            )
            metrics_row += 1
        if metrics_row < metrics_height - 1:
            metrics_win.addnstr(
                metrics_row,
                1,
                format_value(f"Hash Trend: {make_sparkline(self.hashrate_history, 24)}", width - form_width - 3),
                width - form_width - 3,
                self.colors["good"],
            )

        log_body_height = log_height - 2
        for row, line in enumerate(self.log_lines[-log_body_height:]):
            log_win.addnstr(
                row + 1,
                1,
                format_value(line, width - form_width - 3),
                width - form_width - 3,
                log_attr(self.colors, line),
            )

        stdscr.refresh()
        form_win.refresh()
        metrics_win.refresh()
        log_win.refresh()

    def loop(self, stdscr: Any) -> None:
        self.colors = init_colors()
        curses.curs_set(0)
        stdscr.timeout(1000)
        self.refresh()
        while True:
            if time.time() - self.last_refresh >= 2:
                self.refresh()
            self.draw(stdscr)
            key = stdscr.getch()
            if key == -1:
                continue
            if key in (ord("q"), 27):
                break
            if key == curses.KEY_UP:
                self.selected_index = max(0, self.selected_index - 1)
            elif key == curses.KEY_DOWN:
                self.selected_index = min(len(FIELD_ORDER) - 1, self.selected_index + 1)
            elif key in (curses.KEY_ENTER, 10, 13):
                self.edit_selected_field(stdscr)
            elif key == ord("s"):
                try:
                    self.save()
                except Exception as exc:
                    self.message = f"Save failed: {exc}"
            elif key == ord("r"):
                self.run_service_action("restart")
            elif key == ord("x"):
                self.run_service_action("start")
            elif key == ord("z"):
                self.run_service_action("stop")
            elif key == ord("a"):
                self.apply_gpu_tuning()
            elif key == ord("g"):
                self.refresh()


def main() -> int:
    repo_root = Path(__file__).resolve().parents[1]
    default_env = Path.home() / ".config" / "vast-prl-host-miner.env"
    if not default_env.exists():
        default_env = repo_root / "config" / "vast-prl-host-miner.env.example"
    parser = argparse.ArgumentParser(description="Terminal control panel for the Vast PRL miner.")
    parser.add_argument("--env-file", default=str(default_env), help="Path to the miner env file")
    parser.add_argument("--service-name", default="vast-prl-host-miner", help="Systemd service name")
    args = parser.parse_args()

    app = MinerControlApp(Path(args.env_file).expanduser(), args.service_name)
    curses.wrapper(app.loop)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
