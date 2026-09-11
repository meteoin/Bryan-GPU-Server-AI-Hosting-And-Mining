# Terminal Miner Control Plan

This document describes how a terminal-based control application can be built on top of the current Bryan GPU server repo.

The goal is a local terminal UI that lets the operator:

- change miner-related variables without editing shell files by hand
- view live GPU and miner status in one place
- keep the existing `systemd` + watcher flow intact
- rely on NVIDIA driver tooling only for GPU controls

This is a design and feasibility document first. It is written against the current repo state before any UI code is added.

## Current repo baseline

The repo already has the core runtime pieces we need:

- `config/vast-prl-host-miner.env.example`
  - stores operator-editable runtime values such as `MACHINE_ID`, `PRL_WALLET`, `WORKER_NAME`, `POOL`, and timing/debounce settings
- `scripts/vast_prl_host_miner_launcher.sh`
  - converts environment variables into the Python watcher command line
- `scripts/vast_idle_host_miner.py`
  - decides whether mining should be running and starts or stops the miner
- `systemd/vast-prl-host-miner.service`
  - keeps the watcher alive under `systemd`
- `~/.local/state/vast-host-miner/<machine_id>/miner.log`
  - contains the miner's live output
- `~/.local/state/vast-host-miner/<machine_id>/state.json`
  - contains watcher state and recent observed machine data

That means the terminal app does not need to replace the current system. It only needs to become the operator-facing control and observability layer for it.

## Requested controls and whether they are possible

### 1. `Miner`

Possible: yes.

How it would work:

- add a configurable `MINER_BIN` variable to the runtime config
- optionally add a `MINER_KIND` variable if we want named miner presets
- let the terminal app present either:
  - a free-path field such as `/home/flyanb/srbminer/SRBMiner-MULTI`
  - or a preset picker with entries like `SRBMiner`, `custom binary`

Current repo status:

- the launcher already supports `MINER_BIN`, but the example env file does not expose it yet
- the watcher itself does not care which miner is used as long as the binary path exists and the miner arguments are valid

Implementation note:

- the app should validate the binary path before saving
- the app should not allow applying a miner binary that fails `--help` or basic existence checks

### 2. `Pool`

Possible: yes.

How it would work:

- keep using the existing `POOL` and `POOL_PASSWORD` environment variables
- expose them in editable form fields in the terminal app
- save changes to the runtime config, then restart `vast-prl-host-miner`

Current repo status:

- already supported in `config/vast-prl-host-miner.env.example`
- already passed through the launcher into the miner command line

Implementation note:

- the app should allow pool presets and free text
- example preset format:
  - `pearl-us-west.luckypool.io:3360`
  - `pearl-us-central.luckypool.io:3360`

### 3. `gpu pl` (power limit)

Possible: yes, with NVIDIA driver support.

How it would work:

- use `nvidia-smi -pl <watts>` to set the board power limit
- store the desired value in config
- apply it through a helper action before starting the miner, or as an explicit operator action in the terminal app

What we need to be careful about:

- the command usually requires elevated privileges
- supported min/max values vary by GPU and driver
- the app must query limits before allowing a value

Recommended implementation:

- read supported range from:
  - `nvidia-smi -q -d POWER`
- show:
  - current limit
  - default limit
  - min and max limit
- reject values outside the device-reported range

### 4. `gpu mclk` (memory clock)

Possible: maybe, depending on what the installed driver exposes for this GPU.

How it would work:

- first probe supported capabilities rather than assuming they exist
- possible driver-only paths:
  - `nvidia-smi -lmc <min,max>` if memory clock locking is supported
  - `nvidia-smi -ac <mem,graphics>` on GPUs that support application clocks

What we need to be careful about:

- not every NVIDIA GPU exposes memory clock control through `nvidia-smi`
- not every driver branch exposes the same clock-setting modes
- CMP 170HX may allow fewer tuning controls than a consumer card

Recommended implementation:

- the terminal app should have a capability probe at startup
- if memory-clock controls are unsupported, the field should appear read-only or disabled with a clear note
- do not fake support in the UI

### 5. `gpu cclk` (core clock)

Possible: maybe, depending on driver support.

How it would work:

- use `nvidia-smi -lgc <min,max>` if graphics clock locking is supported
- otherwise fall back to read-only display

What we need to be careful about:

- some GPUs allow clock observation but not clock locking
- valid values depend on the supported clock table for the specific GPU

Recommended implementation:

- discover supported clock steps from `nvidia-smi -q -d SUPPORTED_CLOCKS`
- populate the UI with only valid values
- fail closed if the command is unsupported

## Requested view panels and whether they are possible

### 1. GPU temperatures

Possible: yes.

How it would work:

- poll `nvidia-smi` on a short interval such as every 2 seconds
- read:
  - `index`
  - `name`
  - `temperature.gpu`
  - `power.draw`
  - `power.limit`
  - `clocks.current.graphics`
  - `clocks.current.memory`
  - `utilization.gpu`
  - `memory.used`
  - `memory.total`

Recommended command pattern:

```bash
nvidia-smi --query-gpu=index,name,temperature.gpu,power.draw,power.limit,clocks.current.graphics,clocks.current.memory,utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits
```

### 2. Hashrate

Possible: yes.

There are two practical options.

Option A: parse `miner.log`

- simplest and already compatible with the current repo
- extract hashrate lines from SRBMiner output
- show:
  - current hashrate
  - 1 min
  - 1 hr
  - accepted shares
  - rejected shares

Option B: query a local miner API if the selected miner exposes one

- cleaner long-term if we later support more miners
- not required for the first version

Recommended first version:

- use log parsing because `miner.log` already exists and is the lowest-risk path

### 3. Miner logs

Possible: yes.

How it would work:

- tail the existing `miner.log`
- render the last N lines in a scrolling pane
- follow updates while the miner is running

Recommended implementation:

- read from `~/.local/state/vast-host-miner/<machine_id>/miner.log`
- keep an in-memory ring buffer in the UI so the display remains fast

## Additional operator panels that fit naturally

These were not explicitly requested, but they would make the terminal app much more useful:

- watcher status
  - current `idle` / `busy` / `unknown`
  - reason from `state.json`
- Vast occupancy status
  - last observed instance ID
  - last observed `actual_status` and `cur_state`
- service status
  - whether `vast-prl-host-miner.service` is active
- active command preview
  - the exact miner command the launcher will run
- action bar
  - save config
  - reload config
  - restart watcher
  - stop watcher
  - start watcher
  - apply GPU tuning now
  - revert GPU tuning to defaults

## Recommended architecture

## UI framework

Recommended: Python + `Textual`

Reason:

- terminal-native layout and widgets
- good support for forms, tables, logs, timers, and keyboard shortcuts
- fits the existing Python-based repo

Alternative:

- `urwid` if we want lower-level control and fewer dependencies

Recommendation:

- use `Textual` for the first implementation

## Runtime model

The terminal app should not own mining directly. It should manage configuration and observe the existing service.

Suggested structure:

- `miner_tui.py`
  - entry point for the terminal app
- `control/config.py`
  - parse and write env-style config
- `control/gpu.py`
  - read GPU stats and apply NVIDIA driver commands
- `control/service.py`
  - read and control `systemd` status
- `control/logs.py`
  - tail miner logs
- `control/watcher_state.py`
  - read watcher `state.json`

## Config model

The terminal app should manage two categories of settings.

Category A: existing watcher/miner config

- `MACHINE_ID`
- `PRL_WALLET`
- `WORKER_NAME`
- `POOL`
- `POOL_PASSWORD`
- `POLL_SECONDS`
- `MIN_IDLE_POLLS`
- `MIN_BUSY_POLLS`
- `RECONCILE_INTERVAL`
- `STOP_TIMEOUT_SECONDS`
- `MINER_BIN`

Category B: new GPU tuning config

- `GPU_POWER_LIMIT`
- `GPU_MEMORY_CLOCK`
- `GPU_CORE_CLOCK`
- `GPU_TUNING_ENABLED`

Recommendation:

- keep the existing env file for watcher settings
- add the new GPU tuning fields there as optional entries
- keep the launcher backward-compatible when the new fields are absent

## How the terminal app would apply changes

### Non-GPU settings

For `miner`, `pool`, and related runtime values:

1. load the env file
2. update the values
3. validate them
4. write the env file back atomically
5. restart `vast-prl-host-miner.service`

### GPU settings

For `pl`, `mclk`, and `cclk`:

1. probe driver capabilities
2. validate requested values against supported ranges
3. apply the change through `nvidia-smi`
4. persist the chosen values in config
5. optionally reapply them on watcher start

Recommendation:

- the app should separate:
  - `Save config`
  - `Apply GPU tuning now`
- this reduces the risk of a config typo immediately changing clocks

## Where GPU tuning should be applied

There are three possible places.

### Option 1. Inside the terminal app only

Pros:

- simplest to implement first

Cons:

- settings are only applied when the app is used

### Option 2. Inside the launcher before starting the watcher

Pros:

- settings reapply on every service restart
- keeps the runtime behavior deterministic

Cons:

- launcher logic becomes more complex

### Option 3. Separate helper script called by both the app and launcher

Pros:

- cleanest long-term design
- one implementation for probing and applying GPU settings

Cons:

- one extra file

Recommendation:

- use Option 3
- create a helper such as `gpu_tuning.sh` or `gpu_tuning.py`
- let the terminal app call it
- let the launcher optionally call it before running the watcher

## Security and privilege model

This matters because GPU tuning and service control may require `sudo`.

### Likely privilege needs

- reading `nvidia-smi`: usually no `sudo`
- setting power limit or clocks: often needs `sudo`
- restarting `systemd` service: needs `sudo`
- reading miner log and state files: usually fine as the same user

### Recommended safe approach

- keep the TUI itself running as the regular operator user
- use narrowly scoped helper commands for privileged actions
- avoid running the whole TUI under `sudo`

Possible operator model:

- read-only panels always available
- privileged actions prompt or shell out through `sudo`

## Failure handling requirements

The terminal app should be explicit about failures and unsupported controls.

Examples:

- if memory clock control is unsupported, say so and disable the field
- if service restart fails, show stderr and keep the old config visible
- if a miner path is invalid, block save
- if the watcher is busy because Vast has an active instance, show that reason directly from the watcher state

## First-version scope recommendation

Phase 1 should stay intentionally small:

- editable `miner` path
- editable `pool`
- editable `pool password`
- editable `worker name`
- editable `gpu pl`
- live GPU metrics pane
- live miner log pane
- watcher state pane
- start / stop / restart service actions

Phase 2 can add:

- `gpu mclk`
- `gpu cclk`
- miner presets
- pool presets
- richer hashrate parsing and charts
- capability-driven multi-GPU tuning support

## Feasibility summary by requested feature

- Miner selection: yes, already fits the launcher model
- Pool selection: yes, already env-backed
- GPU power limit: yes, through `nvidia-smi -pl`, usually privileged
- GPU memory clock: maybe, depends on driver and GPU support
- GPU core clock: maybe, depends on driver and GPU support
- GPU temps view: yes, directly from `nvidia-smi`
- Hashrate view: yes, parse `miner.log` first
- Miner logs view: yes, tail the existing log file

## What should be built next

The next implementation step should be:

1. add the missing optional config keys to `config/vast-prl-host-miner.env.example`
2. add a small GPU capability/apply helper
3. build a first `Textual` terminal app around:
   - env editing
   - GPU stats polling
   - log tailing
   - `systemd` control
   - watcher state display

That gives an operator-friendly terminal interface without changing the tested idle/busy mining logic.
