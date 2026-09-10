#!/usr/bin/env python3
"""
Best-effort Vast.ai idle watcher for a host-native miner process.

This script does not use `vastai set defjob`. Instead, it polls the host's
machine state and starts/stops a local miner command directly on the server:

  - if the machine looks clearly idle, it starts the configured miner command
  - if the machine looks busy or state is ambiguous, it stops the miner

It is intentionally conservative. On ambiguity or watcher errors, it stops the
miner rather than keeping it alive.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import shlex
import shutil
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any


BUSY_BOOL_KEYS = (
    "rented",
    "is_rented",
    "busy",
    "claimed",
    "reserved",
)

BUSY_COUNT_KEYS = (
    "active_contracts",
    "active_instances",
    "running_instances",
    "num_instances",
    "rented_gpus",
    "num_active_rentals",
    "current_rentals_on_demand",
    "current_rentals_reserved",
    "current_rentals_resident",
    "current_rentals_running",
    "current_rentals_running_on_demand",
    "current_rentals_running_reserved",
)

BUSY_TEXT_KEYS = (
    "status",
    "state",
    "machine_status",
)

BUSY_TEXT_TOKENS = (
    "rented",
    "busy",
    "claimed",
    "occupied",
    "in use",
    "in_use",
)

IDLE_TEXT_TOKENS = (
    "idle",
    "available",
    "unrented",
)


@dataclass
class DetectResult:
    state: str
    reasons: list[str]


def log(message: str) -> None:
    print(f"[vast-host-miner] {message}", flush=True)


def run_command(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, capture_output=True, text=True)


def require_command(name: str) -> None:
    if not shutil.which(name):
        raise RuntimeError(f"required command not found in PATH: {name}")


def require_executable(path_text: str) -> None:
    path = Path(path_text).expanduser()
    if not path.exists():
        raise RuntimeError(f"miner executable not found: {path}")
    if not os.access(path, os.X_OK):
        raise RuntimeError(f"miner executable is not executable: {path}")


def run_vastai_json(args: list[str]) -> Any:
    cmd = ["vastai", *args, "--raw"]
    result = run_command(cmd)
    if result.returncode != 0:
        stderr = result.stderr.strip() or "(no stderr)"
        raise RuntimeError(f"{shlex.join(cmd)} failed: {stderr}")

    stdout = result.stdout.strip()
    if not stdout:
        return {}

    try:
        return json.loads(stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(
            f"{shlex.join(cmd)} returned non-JSON output: {stdout}"
        ) from exc


def normalize_machine_list(payload: Any) -> list[dict[str, Any]]:
    if isinstance(payload, dict):
        if isinstance(payload.get("machines"), list):
            return [item for item in payload["machines"] if isinstance(item, dict)]
        if "id" in payload:
            return [payload]
    if isinstance(payload, list):
        return [item for item in payload if isinstance(item, dict)]
    return []


def find_machine(payload: Any, machine_id: int) -> dict[str, Any] | None:
    for machine in normalize_machine_list(payload):
        try:
            if int(machine.get("id")) == machine_id:
                return machine
        except (TypeError, ValueError):
            continue
    return None


def load_machine(machine_id: int) -> dict[str, Any]:
    payload = run_vastai_json(["show", "machines"])
    machine = find_machine(payload, machine_id)
    if not machine:
        raise RuntimeError(f"machine {machine_id} not found in `vastai show machines --raw`")
    return machine


def occupancy_idle(value: Any) -> bool | None:
    if value is None:
        return None
    text = str(value).strip().lower()
    if not text:
        return None
    alnum = [char for char in text if char.isalnum()]
    if not alnum:
        return None
    return all(char == "x" for char in alnum)


def detect_machine_state(machine: dict[str, Any]) -> DetectResult:
    reasons: list[str] = []

    for key in BUSY_BOOL_KEYS:
        value = machine.get(key)
        if value is True:
            reasons.append(f"{key}=true")
            return DetectResult("busy", reasons)

    for key in BUSY_COUNT_KEYS:
        value = machine.get(key)
        try:
            if value is not None and float(value) > 0:
                reasons.append(f"{key}={value}")
                return DetectResult("busy", reasons)
        except (TypeError, ValueError):
            continue

    for key in BUSY_TEXT_KEYS:
        value = machine.get(key)
        if value is None:
            continue
        lowered = str(value).strip().lower()
        if any(token in lowered for token in BUSY_TEXT_TOKENS):
            reasons.append(f"{key}={value}")
            return DetectResult("busy", reasons)
        if any(token in lowered for token in IDLE_TEXT_TOKENS):
            reasons.append(f"{key}={value}")
            return DetectResult("idle", reasons)

    occup = machine.get("occup")
    if occup is None:
        occup = machine.get("gpu_occupancy")
    occup_idle = occupancy_idle(occup)
    if occup_idle is True:
        reasons.append(f"occup={occup}")
        return DetectResult("idle", reasons)
    if occup_idle is False:
        reasons.append(f"occup={occup}")
        return DetectResult("busy", reasons)

    return DetectResult("unknown", ["no reliable idle/busy signal found"])


def default_state_dir(machine_id: int) -> Path:
    xdg_state_home = os.environ.get("XDG_STATE_HOME")
    if xdg_state_home:
        base = Path(xdg_state_home)
    else:
        base = Path.home() / ".local" / "state"
    return base / "vast-host-miner" / str(machine_id)


def load_state(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError:
        return {}


def save_state(path: Path, state: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")


def acquire_lock(path: Path) -> Any:
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = path.open("a+")
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as exc:
        handle.close()
        raise RuntimeError(f"another host-miner watcher is already running (lock: {path})") from exc
    handle.seek(0)
    handle.truncate()
    handle.write(str(os.getpid()) + "\n")
    handle.flush()
    return handle


def update_observation_state(
    state: dict[str, Any],
    observed_state: str,
    reasons: list[str],
    machine: dict[str, Any],
) -> dict[str, Any]:
    previous = state.get("observed_state")
    previous_count = state.get("observed_count", 0)
    if previous == observed_state:
        count = int(previous_count) + 1 if isinstance(previous_count, int) else 1
    else:
        count = 1

    state["observed_state"] = observed_state
    state["observed_count"] = count
    state["observed_reasons"] = reasons
    state["last_observed_epoch"] = time.time()
    state["last_machine_snapshot"] = {
        "id": machine.get("id"),
        "hostname": machine.get("hostname"),
        "status": machine.get("status"),
        "state": machine.get("state"),
        "occup": machine.get("occup"),
        "gpu_occupancy": machine.get("gpu_occupancy"),
        "current_rentals_on_demand": machine.get("current_rentals_on_demand"),
        "current_rentals_resident": machine.get("current_rentals_resident"),
        "current_rentals_running": machine.get("current_rentals_running"),
    }
    return state


def desired_action_for_observation(args: argparse.Namespace, state: dict[str, Any]) -> tuple[str, str]:
    observed_state = state.get("observed_state", "unknown")
    observed_count = state.get("observed_count", 0)

    if observed_state == "idle" and isinstance(observed_count, int) and observed_count >= args.min_idle_polls:
        return ("start", f"idle seen {observed_count} consecutive poll(s)")

    if observed_state != "idle" and isinstance(observed_count, int) and observed_count >= args.min_busy_polls:
        return ("stop", f"{observed_state} seen {observed_count} consecutive poll(s)")

    return ("hold", f"waiting for debounce threshold: state={observed_state} count={observed_count}")


def pid_running(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def read_proc_cmdline(pid: int) -> list[str] | None:
    """
    Best-effort read of a process command line on Linux.

    Returns None if /proc is unavailable or the command line can't be read.
    """
    proc_path = Path("/proc") / str(pid) / "cmdline"
    try:
        data = proc_path.read_bytes()
    except OSError:
        return None
    if not data:
        return []
    parts = [part.decode(errors="replace") for part in data.split(b"\x00") if part]
    return parts


def pid_looks_like_process(pid: int, expected_exec: str) -> bool | None:
    """
    Returns:
      - True if the PID likely matches expected_exec
      - False if it likely does not
      - None if we can't determine (e.g., /proc not available)
    """
    cmdline = read_proc_cmdline(pid)
    if cmdline is None:
        return None
    if not cmdline:
        return False

    expected_path = os.path.realpath(str(Path(expected_exec).expanduser()))
    argv0 = cmdline[0]
    argv0_path = os.path.realpath(argv0) if argv0 else ""

    if argv0_path and expected_path and argv0_path == expected_path:
        return True
    if expected_path and expected_path in cmdline:
        return True
    if Path(argv0).name and Path(expected_path).name and Path(argv0).name == Path(expected_path).name:
        return True
    return False


def should_reconcile(state: dict[str, Any], desired_action: str, reconcile_interval: int) -> bool:
    if state.get("last_action") != desired_action:
        return True
    last_change = state.get("last_change_epoch")
    if not isinstance(last_change, (int, float)):
        return True
    return (time.time() - float(last_change)) >= reconcile_interval


def mark_action(state: dict[str, Any], action: str) -> None:
    if state.get("last_action") != action:
        state["last_action"] = action
        state["last_change_epoch"] = time.time()


def start_miner(args: argparse.Namespace, state: dict[str, Any]) -> dict[str, Any]:
    existing_pid = state.get("miner_pid")
    if isinstance(existing_pid, int) and pid_running(existing_pid):
        looks_like = pid_looks_like_process(existing_pid, args.miner_exec)
        if looks_like is False:
            log(
                f"clearing stale miner pid {existing_pid} "
                f"(pid is running but does not look like {Path(args.miner_exec).name})"
            )
            state.pop("miner_pid", None)
            state.pop("miner_process_group", None)
            state["miner_status"] = "stopped"
        else:
            if state.get("miner_status") != "running":
                log(f"miner already running with pid {existing_pid}")
            state["miner_status"] = "running"
            mark_action(state, "start")
            return state
    if isinstance(existing_pid, int):
        log(f"clearing stale miner pid {existing_pid}")
        state.pop("miner_pid", None)
        state.pop("miner_process_group", None)
        state["miner_status"] = "stopped"

    if not should_reconcile(state, "start", args.reconcile_interval):
        return state

    cmd = [args.miner_exec, *args.miner_arg]
    log_path = Path(args.miner_log_file)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    command_str = shlex.join(cmd)

    if args.dry_run:
        log(f"dry-run: would start miner: {command_str}")
        mark_action(state, "start")
        state["last_miner_command"] = command_str
        state["miner_status"] = "running"
        return state

    with log_path.open("a", encoding="utf-8") as handle:
        handle.write(f"\n===== {time.strftime('%Y-%m-%d %H:%M:%S')} starting miner =====\n")
        handle.write(f"command: {command_str}\n")
        handle.flush()
        process = subprocess.Popen(
            cmd,
            stdout=handle,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            text=True,
        )

    state["miner_pid"] = process.pid
    state["miner_process_group"] = process.pid
    state["miner_log_file"] = str(log_path)
    state["last_miner_command"] = command_str
    state["miner_started_epoch"] = time.time()
    state["miner_status"] = "running"
    mark_action(state, "start")
    log(f"started miner with pid {process.pid}")
    return state


def stop_miner(
    args: argparse.Namespace,
    state: dict[str, Any],
    reason: str,
    *,
    force: bool = False,
) -> dict[str, Any]:
    if not force and not should_reconcile(state, "stop", args.reconcile_interval):
        return state

    pid = state.get("miner_pid")
    if not isinstance(pid, int) or not pid_running(pid):
        if state.get("miner_status") != "stopped":
            log(f"miner already stopped ({reason})")
        state.pop("miner_pid", None)
        state.pop("miner_process_group", None)
        state["miner_status"] = "stopped"
        mark_action(state, "stop")
        return state

    if args.dry_run:
        log(f"dry-run: would stop miner pid {pid} ({reason})")
        state["miner_status"] = "stopped"
        mark_action(state, "stop")
        return state

    log(f"stopping miner pid {pid} ({reason})")
    process_group = state.get("miner_process_group", pid)
    try:
        os.killpg(int(process_group), signal.SIGTERM)
    except ProcessLookupError:
        pass

    deadline = time.time() + args.stop_timeout_seconds
    while time.time() < deadline:
        if not pid_running(pid):
            break
        time.sleep(0.5)

    if pid_running(pid):
        log(f"miner pid {pid} did not exit after SIGTERM, sending SIGKILL")
        try:
            os.killpg(int(process_group), signal.SIGKILL)
        except ProcessLookupError:
            pass

    state.pop("miner_pid", None)
    state.pop("miner_process_group", None)
    state["miner_stopped_epoch"] = time.time()
    state["miner_status"] = "stopped"
    mark_action(state, "stop")
    return state


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Manage a host-native miner process only while a Vast machine appears idle."
    )
    parser.add_argument("--machine-id", type=int, required=True, help="Vast machine ID")
    parser.add_argument("--miner-exec", required=True, help="Absolute path to the miner binary or wrapper script")
    parser.add_argument(
        "--miner-arg",
        action="append",
        default=[],
        help="Repeat for each argument passed to the miner process",
    )
    parser.add_argument("--poll-seconds", type=int, default=5, help="Polling interval in seconds")
    parser.add_argument(
        "--min-idle-polls",
        type=int,
        default=2,
        help="Consecutive idle polls required before starting the miner",
    )
    parser.add_argument(
        "--min-busy-polls",
        type=int,
        default=1,
        help="Consecutive busy/unknown polls required before stopping the miner",
    )
    parser.add_argument(
        "--reconcile-interval",
        type=int,
        default=60,
        help="Minimum seconds between repeating the same start/stop action",
    )
    parser.add_argument(
        "--stop-timeout-seconds",
        type=int,
        default=20,
        help="Seconds to wait after SIGTERM before SIGKILL",
    )
    parser.add_argument(
        "--state-file",
        default="",
        help="Optional path for watcher state (default: ~/.local/state/vast-host-miner/<machine>/state.json)",
    )
    parser.add_argument(
        "--lock-file",
        default="",
        help="Optional path for a single-instance lock (default: ~/.local/state/vast-host-miner/<machine>/watcher.lock)",
    )
    parser.add_argument(
        "--miner-log-file",
        default="",
        help="Optional miner stdout/stderr log path (default: ~/.local/state/vast-host-miner/<machine>/miner.log)",
    )
    parser.add_argument("--once", action="store_true", help="Run one poll/reconcile cycle and exit")
    parser.add_argument("--dry-run", action="store_true", help="Log actions without starting/stopping the miner")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    require_command("vastai")
    require_executable(args.miner_exec)

    state_dir = default_state_dir(args.machine_id)
    state_path = Path(args.state_file) if args.state_file else state_dir / "state.json"
    lock_path = Path(args.lock_file) if args.lock_file else state_dir / "watcher.lock"
    args.miner_log_file = args.miner_log_file or str(state_dir / "miner.log")

    state = load_state(state_path)
    lock_handle = acquire_lock(lock_path)
    shutdown_requested = False

    def handle_signal(signum: int, _frame: Any) -> None:
        nonlocal shutdown_requested
        shutdown_requested = True
        log(f"received signal {signum}, shutting down")

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    try:
        while True:
            if shutdown_requested:
                break
            try:
                machine = load_machine(args.machine_id)
                detect = detect_machine_state(machine)
                state = update_observation_state(state, detect.state, detect.reasons, machine)
                desired_action, action_reason = desired_action_for_observation(args, state)
                log(
                    f"machine {args.machine_id} state={detect.state} "
                    f"count={state.get('observed_count')} "
                    f"decision={desired_action} "
                    f"({'; '.join(detect.reasons)})"
                )

                if desired_action == "start":
                    state = start_miner(args, state)
                elif desired_action == "stop":
                    state = stop_miner(args, state, action_reason)
                else:
                    log(action_reason)

                save_state(state_path, state)
            except Exception as exc:
                log(f"error: {exc}")
                try:
                    state = stop_miner(args, state, "watcher-error")
                    save_state(state_path, state)
                except Exception as stop_exc:
                    log(f"cleanup error: {stop_exc}")
                if args.once:
                    return 1

            if args.once:
                return 0

            time.sleep(max(1, args.poll_seconds))
    finally:
        try:
            state = stop_miner(args, state, "watcher-shutdown", force=True)
            save_state(state_path, state)
        except Exception as stop_exc:
            log(f"shutdown cleanup error: {stop_exc}")
        lock_handle.close()

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
