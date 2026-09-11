#!/usr/bin/env python3
"""
Best-effort Vast.ai idle mining watcher.

This script manages a host-side default/background job via:
  - `vastai set defjob`
  - `vastai remove defjob`

It is intentionally conservative:
  - if the machine looks clearly idle, it ensures the default mining job exists
  - if the machine looks busy or state is ambiguous, it removes the default job

It does not claim any special Vast preemption support. It is just a poller that
reconciles desired state against the current machine snapshot.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import shlex
import shutil
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
    print(f"[vast-idle-watcher] {message}", flush=True)


def run_command(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, capture_output=True, text=True)


def require_command(name: str) -> None:
    if not shutil.which(name):
        raise RuntimeError(f"required command not found in PATH: {name}")


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


def run_vastai_action(args: list[str], dry_run: bool) -> None:
    cmd = ["vastai", *args]
    if dry_run:
        log(f"dry-run: {shlex.join(cmd)}")
        return

    result = run_command(cmd)
    stdout = result.stdout.strip()
    stderr = result.stderr.strip()

    if result.returncode != 0:
        detail = stderr or stdout or "(no output)"
        raise RuntimeError(f"{shlex.join(cmd)} failed: {detail}")

    if stdout:
        log(stdout)
    elif stderr:
        log(stderr)


def normalize_machine_list(payload: Any) -> list[dict[str, Any]]:
    if isinstance(payload, dict):
        if isinstance(payload.get("machines"), list):
            return [item for item in payload["machines"] if isinstance(item, dict)]
        if all(isinstance(value, (str, int, float, bool, list, dict, type(None))) for value in payload.values()):
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
        return ("set", f"idle seen {observed_count} consecutive poll(s)")

    if observed_state != "idle" and isinstance(observed_count, int) and observed_count >= args.min_busy_polls:
        return ("remove", f"{observed_state} seen {observed_count} consecutive poll(s)")

    return ("hold", f"waiting for debounce threshold: state={observed_state} count={observed_count}")


def should_reconcile(state: dict[str, Any], desired_action: str, reconcile_interval: int) -> bool:
    if state.get("last_action") != desired_action:
        return True
    last_change = state.get("last_change_epoch")
    if not isinstance(last_change, (int, float)):
        return True
    return (time.time() - float(last_change)) >= reconcile_interval


def ensure_defjob(machine_id: int, args: argparse.Namespace, state: dict[str, Any]) -> dict[str, Any]:
    if not should_reconcile(state, "set", args.reconcile_interval):
        return state

    cmd = [
        "set",
        "defjob",
        str(machine_id),
        "--price_gpu",
        str(args.price_gpu),
        "--price_inetu",
        str(args.price_inetu),
        "--price_inetd",
        str(args.price_inetd),
        "--image",
        args.image,
    ]

    for job_arg in args.job_arg:
        cmd.extend(["--args", job_arg])

    log(f"ensuring default mining job exists for machine {machine_id}")
    run_vastai_action(cmd, args.dry_run)

    state["last_action"] = "set"
    state["last_change_epoch"] = time.time()
    return state


def remove_defjob(machine_id: int, args: argparse.Namespace, state: dict[str, Any], reason: str) -> dict[str, Any]:
    if not should_reconcile(state, "remove", args.reconcile_interval):
        return state

    log(f"removing default mining job for machine {machine_id} ({reason})")
    try:
        run_vastai_action(["remove", "defjob", str(machine_id)], args.dry_run)
    except RuntimeError as exc:
        # Keep the watcher resilient if defjob is already missing.
        message = str(exc)
        if "404" not in message and "not found" not in message.lower():
            raise
        log(f"remove defjob reported no existing job: {message}")

    state["last_action"] = "remove"
    state["last_change_epoch"] = time.time()
    return state


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Manage a Vast.ai background mining job only while a machine appears idle."
    )
    parser.add_argument("--machine-id", type=int, required=True, help="Vast machine ID")
    parser.add_argument("--image", required=True, help="Docker image for the mining job")
    parser.add_argument(
        "--job-arg",
        action="append",
        default=[],
        help="Repeat for each argument passed to the mining container",
    )
    parser.add_argument("--price-gpu", type=float, required=True, help="GPU price passed to set defjob")
    parser.add_argument("--price-inetu", type=float, default=0.0, help="Upload bandwidth price")
    parser.add_argument("--price-inetd", type=float, default=0.0, help="Download bandwidth price")
    parser.add_argument("--poll-seconds", type=int, default=5, help="Polling interval in seconds")
    parser.add_argument(
        "--min-idle-polls",
        type=int,
        default=2,
        help="Consecutive idle polls required before setting the default mining job",
    )
    parser.add_argument(
        "--min-busy-polls",
        type=int,
        default=1,
        help="Consecutive busy/unknown polls required before removing the default mining job",
    )
    parser.add_argument(
        "--reconcile-interval",
        type=int,
        default=60,
        help="Minimum seconds between repeating the same set/remove action",
    )
    parser.add_argument(
        "--state-file",
        default="",
        help="Optional path for watcher state (default: ~/.local/state/vast-idle-watcher/<machine>.json)",
    )
    parser.add_argument(
        "--lock-file",
        default="",
        help="Optional path for a single-instance lock (default: ~/.local/state/vast-idle-watcher/<machine>.lock)",
    )
    parser.add_argument("--once", action="store_true", help="Run one poll/reconcile cycle and exit")
    parser.add_argument("--dry-run", action="store_true", help="Log actions without changing Vast state")
    return parser.parse_args(argv)


def default_state_path(machine_id: int) -> Path:
    xdg_state_home = os.environ.get("XDG_STATE_HOME")
    if xdg_state_home:
        base = Path(xdg_state_home)
    else:
        base = Path.home() / ".local" / "state"
    return base / "vast-idle-watcher" / f"{machine_id}.json"


def default_lock_path(machine_id: int) -> Path:
    return default_state_path(machine_id).with_suffix(".lock")


def acquire_lock(path: Path) -> Any:
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = path.open("a+")
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as exc:
        handle.close()
        raise RuntimeError(f"another watcher instance is already running (lock: {path})") from exc
    handle.seek(0)
    handle.truncate()
    handle.write(str(os.getpid()) + "\n")
    handle.flush()
    return handle


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    require_command("vastai")
    state_path = Path(args.state_file) if args.state_file else default_state_path(args.machine_id)
    lock_path = Path(args.lock_file) if args.lock_file else default_lock_path(args.machine_id)
    state = load_state(state_path)
    lock_handle = acquire_lock(lock_path)

    try:
        while True:
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

                if desired_action == "set":
                    state = ensure_defjob(args.machine_id, args, state)
                elif desired_action == "remove":
                    state = remove_defjob(args.machine_id, args, state, action_reason)
                else:
                    log(action_reason)

                save_state(state_path, state)
            except Exception as exc:
                log(f"error: {exc}")
                # Fail safe: on ambiguous watcher errors, try to remove defjob once.
                try:
                    state = remove_defjob(args.machine_id, args, state, "watcher-error")
                    save_state(state_path, state)
                except Exception as remove_exc:
                    log(f"cleanup error: {remove_exc}")
                if args.once:
                    return 1

            if args.once:
                return 0

            time.sleep(max(1, args.poll_seconds))
    finally:
        lock_handle.close()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
