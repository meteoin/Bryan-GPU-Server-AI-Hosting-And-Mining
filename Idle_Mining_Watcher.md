# Vast Idle Mining Watcher

This note describes the host-side watcher script in `vast_idle_mining_watcher.py`.

This is now the secondary path. Bryan's validated setup moved to the host-native watcher in `vast_idle_host_miner.py` because the container path did not expose GPUs reliably on `rigv4`.

## Goal

Use Vast's host-side default/background job feature to launch a mining container only while a machine appears idle, and remove that default job when the machine appears busy.

This is a **best-effort host automation**, not a documented Vast guarantee of instant preemption.

## What the script does

The script polls:

```bash
vastai show machines --raw
```

Then it applies this policy:

- if the machine looks **idle**, run:

```bash
vastai set defjob <machine_id> ...
```

- if the machine looks **busy** or the state is **ambiguous**, run:

```bash
vastai remove defjob <machine_id>
```

It is intentionally conservative. If the machine state cannot be trusted, it removes the default job instead of trying to keep mining alive.

The current script also adds a few host-safety protections:

- a single-instance lock file so two watcher processes do not fight each other
- consecutive-poll debounce before setting or removing the default job
- a persisted JSON state file with the last observed machine snapshot and reasons

## Idle/busy signal

The watcher uses the raw machine JSON and checks:

- explicit busy flags like `rented`, `busy`, `claimed`, `reserved`
- numeric activity counters if present, including Vast's `current_rentals_*` fields
- machine `status` / `state` strings if present
- the `occup` string if present
- the `gpu_occupancy` string used by Bryan's tested hosts

For Bryan's tested machine, an idle host looked like:

```text
gpu_occupancy = x
current_rentals_on_demand = 0
current_rentals_resident = 0
current_rentals_running = 0
```

The watcher treats an all-`x` occupancy string as idle.

## Recommended first test

Do this on `rigv4` first, not on the main production rental host.

Reason:

- Vast docs support `set defjob` and `remove defjob`
- Vast docs do not clearly guarantee the exact auto-stop lifecycle Bryan wants
- `rigv3` is already sensitive around verification and PCIe bandwidth

## Example invocation

This example is kept for reference only. Prefer the host-native PRL flow for live use.

Replace the image and job args with the actual mining image and PRL worker/wallet parameters.

For the client's current preference, use an SRBMiner-based container and LuckyPool's Pearl arguments:

- `--algorithm-gpu pearlhash`
- `--wallet <PRL_ADDRESS>`
- `--worker <RIG_NAME>`
- `--pool pearl-us-west.luckypool.io:3360`

LuckyPool recommends port `3360` for miners under `500 TH/s`, which fits `rigv4`.

```bash
python3 vast_idle_mining_watcher.py \
  --machine-id 150421 \
  --image local/prl-srbminer:latest \
  --job-arg=--algorithm-gpu \
  --job-arg=pearlhash \
  --job-arg=--wallet \
  --job-arg=YOUR_PRL_ADDRESS \
  --job-arg=--worker \
  --job-arg=rigv4 \
  --job-arg=--pool \
  --job-arg=pearl-us-west.luckypool.io:3360 \
  --price-gpu 0.15 \
  --price-inetu 0 \
  --price-inetd 0 \
  --min-idle-polls 2 \
  --min-busy-polls 1 \
  --poll-seconds 5
```

Dry-run first:

```bash
python3 vast_idle_mining_watcher.py \
  --machine-id 150421 \
  --image local/prl-srbminer:latest \
  --job-arg=--algorithm-gpu \
  --job-arg=pearlhash \
  --job-arg=--wallet \
  --job-arg=YOUR_PRL_ADDRESS \
  --job-arg=--worker \
  --job-arg=rigv4 \
  --job-arg=--pool \
  --job-arg=pearl-us-west.luckypool.io:3360 \
  --price-gpu 0.15 \
  --min-idle-polls 2 \
  --dry-run \
  --once
```

Default runtime files:

- state: `~/.local/state/vast-idle-watcher/<machine_id>.json`
- lock: `~/.local/state/vast-idle-watcher/<machine_id>.lock`

## Suggested systemd unit

Example unit file:

```ini
[Unit]
Description=Vast idle mining watcher
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=flyanb
WorkingDirectory=/home/flyanb
ExecStart=/usr/bin/python3 /path/to/vast_idle_mining_watcher.py \
  --machine-id 150421 \
  --image local/prl-srbminer:latest \
  --job-arg=--algorithm-gpu \
  --job-arg=pearlhash \
  --job-arg=--wallet \
  --job-arg=YOUR_PRL_ADDRESS \
  --job-arg=--worker \
  --job-arg=rigv4 \
  --job-arg=--pool \
  --job-arg=pearl-us-west.luckypool.io:3360 \
  --price-gpu 0.15 \
  --price-inetu 0 \
  --price-inetd 0 \
  --min-idle-polls 2 \
  --min-busy-polls 1 \
  --poll-seconds 5
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

## Safety notes

- The watcher manages the **default/background job**, not a guaranteed hard kill of an already running renter workload.
- Polling every `2-5` seconds is more practical than trying to emulate a one-second cron.
- If the machine JSON shape changes, the idle/busy heuristic may need adjustment.
- Keep logs while testing on `rigv4`.
- If the watcher sees a transient idle signal only once, it will wait for the configured idle debounce instead of setting the mining job immediately.

## Recommended validation checklist

1. Run the watcher in `--dry-run --once` mode and confirm it detects idle correctly.
2. Run it live on `rigv4`.
3. Confirm the mining defjob appears.
4. Simulate or observe a renter claim.
5. Confirm the watcher removes the defjob quickly.
6. Confirm the machine remains healthy in Vast afterward.
