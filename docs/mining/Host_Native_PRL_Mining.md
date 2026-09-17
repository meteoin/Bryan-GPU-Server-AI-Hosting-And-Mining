# Host-Native PRL Mining

This note describes the preferred path after the SRBMiner container tests on `rigv4` showed no GPU devices were being exposed inside the container.

Instead of asking Vast to run a mining container as a default job, this path runs the miner directly on the host and lets a watcher start/stop that local process based on `vastai show machines --raw` plus `vastai show instances --raw`.

## Files

- `scripts/vast_idle_host_miner.py`
- `scripts/vast_idle_mining_watcher.py`
- `scripts/vast_prl_host_miner_launcher.sh`
- `scripts/terminal_miner_control.py`
- `scripts/controlpanel`
- `config/vast-prl-host-miner.env.example`
- `systemd/vast-prl-host-miner.service`

Use `scripts/vast_idle_host_miner.py` for the host-native miner path. After install, open the terminal UI with `controlpanel`.

## Why this path

- the idle/busy detection logic already works on Bryan's hosts
- the SRBMiner container build succeeded, but `--list-devices` inside the container returned no GPUs
- host-native SRBMiner avoids the NVIDIA container runtime mismatch entirely

## Install SRBMiner directly on the host

Example on `rigv4`:

```bash
mkdir -p ~/srbminer
cd ~/srbminer
curl -fsSL -o srbminer-linux.tar.gz https://github.com/doktor83/SRBMiner-Multi/releases/download/3.6.2/SRBMiner-Multi-3-6-2-Linux.tar.gz
tar -xzf srbminer-linux.tar.gz
find . -type f -name 'SRBMiner-MULTI' -exec cp {} ~/srbminer/SRBMiner-MULTI \;
chmod +x ~/srbminer/SRBMiner-MULTI
```

Use `3.6.2` for the current tested CMP 170HX path. If you see `Unknown algorithm 'pearlhash'`, you are on an older build.

Quick checks:

```bash
~/srbminer/SRBMiner-MULTI --help
~/srbminer/SRBMiner-MULTI --list-devices
```

## Direct miner test

```bash
~/srbminer/SRBMiner-MULTI \
  --algorithm-gpu pearlhash \
  --wallet prl1p4pzpvqfw4czvyyy6nzgcps6q8nc350nr3736urhl0xqzdk6ekauqtxa7mk \
  --worker rigv4 \
  --pool pearl-us-west.luckypool.io:3360 \
  --password x \
  --disable-cpu \
  --extended-log
```

Success signals:

- `Algorithm/s : pearlhash`
- `Connected to pearl-us-west.luckypool.io:3360`
- `Job received ...`
- accepted shares increasing with low or zero rejects

## Host-native watcher dry-run

```bash
python3 ./scripts/vast_idle_host_miner.py \
  --machine-id 150421 \
  --miner-exec /home/flyanb/srbminer/SRBMiner-MULTI \
  --miner-arg=--algorithm-gpu \
  --miner-arg=pearlhash \
  --miner-arg=--wallet \
  --miner-arg=prl1p4pzpvqfw4czvyyy6nzgcps6q8nc350nr3736urhl0xqzdk6ekauqtxa7mk \
  --miner-arg=--worker \
  --miner-arg=rigv4 \
  --miner-arg=--pool \
  --miner-arg=pearl-us-west.luckypool.io:3360 \
  --miner-arg=--password \
  --miner-arg=x \
  --miner-arg=--disable-cpu \
  --min-idle-polls 2 \
  --dry-run \
  --once
```

## Live watcher run

```bash
python3 ./scripts/vast_idle_host_miner.py \
  --machine-id 150421 \
  --miner-exec /home/flyanb/srbminer/SRBMiner-MULTI \
  --miner-arg=--algorithm-gpu \
  --miner-arg=pearlhash \
  --miner-arg=--wallet \
  --miner-arg=prl1p4pzpvqfw4czvyyy6nzgcps6q8nc350nr3736urhl0xqzdk6ekauqtxa7mk \
  --miner-arg=--worker \
  --miner-arg=rigv4 \
  --miner-arg=--pool \
  --miner-arg=pearl-us-west.luckypool.io:3360 \
  --miner-arg=--password \
  --miner-arg=x \
  --miner-arg=--disable-cpu \
  --min-idle-polls 2 \
  --poll-seconds 5
```

## Preferred launcher flow

Instead of putting the long Python command directly into `systemd`, use the launcher script and an env file.

Make the launcher executable and create the runtime config:

```bash
chmod +x ./scripts/vast_prl_host_miner_launcher.sh
mkdir -p ~/.config
cp ./config/vast-prl-host-miner.env.example ~/.config/vast-prl-host-miner.env
```

Edit `~/.config/vast-prl-host-miner.env` and set:

- `MACHINE_ID`
- `PRL_WALLET`
- `WORKER_NAME`
- `POOL`
- `POOL_PASSWORD`

If you plan to use `GPU_POWER_LIMIT`, `GPU_MEMORY_CLOCK`, or `GPU_CORE_CLOCK`, the watcher and terminal control panel need non-interactive permission to run `nvidia-smi` as root. Without that, the UI may show requested tuning values while the cards stay on the default NVIDIA limits.

Recommended host setup:

```bash
which nvidia-smi
sudo visudo -f /etc/sudoers.d/flyanb-nvidia-smi
```

Add:

```sudoers
flyanb ALL=(root) NOPASSWD: /usr/bin/nvidia-smi
```

Then validate:

```bash
sudo -l
sudo -n nvidia-smi -pl 200
```

Dry-run the launcher first:

```bash
MACHINE_ID=150421 \
PRL_WALLET=prl1p4pzpvqfw4czvyyy6nzgcps6q8nc350nr3736urhl0xqzdk6ekauqtxa7mk \
WORKER_NAME=rigv4 \
DRY_RUN=1 \
./scripts/vast_prl_host_miner_launcher.sh
```

Make sure `vastai show machines` already works for the `flyanb` user before enabling `systemd`. If the CLI is not logged in, the watcher will fail at boot.

## Behavior

- idle for enough consecutive polls: start the miner process
- busy or ambiguous state: stop the miner process
- watcher errors: stop the miner process
- watcher shutdown: stop the miner process cleanly

Runtime files default to:

```bash
~/.local/state/vast-host-miner/<machine_id>/
```

That directory contains:

- `state.json`
- `watcher.lock`
- `miner.log`

## Suggested systemd unit

```ini
[Unit]
Description=Vast idle PRL host miner watcher
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=flyanb
WorkingDirectory=/home/flyanb
Environment=HOME=/home/flyanb
Environment=PATH=/home/flyanb/.local/bin:/usr/local/bin:/usr/bin:/bin
EnvironmentFile=/home/flyanb/.config/vast-prl-host-miner.env
ExecStart=/home/flyanb/vast_prl_host_miner_launcher.sh
Restart=always
RestartSec=5
KillMode=control-group
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
```

Install it like this on the host:

```bash
mkdir -p ~/.config
cp ./config/vast-prl-host-miner.env.example ~/.config/vast-prl-host-miner.env
sudo cp ./systemd/vast-prl-host-miner.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now vast-prl-host-miner.service
```

Useful checks:

```bash
sudo systemctl status vast-prl-host-miner --no-pager
journalctl -u vast-prl-host-miner -f
cat ~/.local/state/vast-host-miner/150421/state.json
tail -f ~/.local/state/vast-host-miner/150421/miner.log
```

Troubleshooting notes:

- If you see `miner already running with pid ...` but mining is not actually running, verify the PID:
  - `ps -fp <pid>`
  - `cat /proc/<pid>/cmdline | tr '\\0' ' '`
  The watcher will now auto-clear a PID that is running but does not look like the configured miner executable.
- If the service appears to stop/start unexpectedly, check for restarts and the exit reason:
  - `journalctl -u vast-prl-host-miner --since "10 minutes ago" --no-pager`
  - `systemctl show -p NRestarts,ExecMainStatus,ExecMainCode vast-prl-host-miner`
- If GPU tuning values are visible in the dashboard but `nvidia-smi` still shows the default `250W` limit, test the privilege path directly:
  - `python3 /home/flyanb/gpu_tuning_helper.py apply --power-limit 200 --state-dir ~/.local/state/vast-host-miner/150421`
  - `nvidia-smi --query-gpu=index,name,power.limit,power.draw --format=csv`
  - if the helper reports `Insufficient Permissions`, the `sudoers` rule for `/usr/bin/nvidia-smi` is missing or incorrect

To stop or pause mining automation:

```bash
sudo systemctl stop vast-prl-host-miner
sudo systemctl disable vast-prl-host-miner
```
