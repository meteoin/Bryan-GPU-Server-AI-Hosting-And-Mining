# GitHub Curl Installer

Operator guide for the one-line installer and the host update service.

The design notes live in `GitHub_Curl_Installer_Plan.md`. This page is the command sequence.

## First install

Run this on the NVIDIA host as the operator user, not as root:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/meteoin/Bryan-GPU-Server-AI-Hosting-And-Mining/main/install.sh)
```

If the repo is private, export a token first:

```bash
export GITHUB_TOKEN=...
```

Non-interactive example for a non-170HX box such as a 5090:

```bash
MACHINE_ID=150421 \
PRL_WALLET=prl1... \
WORKER_NAME=rig-5090 \
bash <(curl -fsSL https://raw.githubusercontent.com/meteoin/Bryan-GPU-Server-AI-Hosting-And-Mining/main/install.sh) \
  --profile miner-only \
  --yes
```

The installer:

1. Detects CMP 170HX vs other NVIDIA GPUs
2. Refuses the 170HX bootstrap on a 5090 or any non-170HX card
3. Installs mining scripts, the terminal app, SRBMiner, a templated systemd miner unit, and the update timer
4. Writes `~/.local/state/bryan-gpu-setup/installed.json`

On 170HX it also runs `scripts/ready_170hx_host.sh`. If that script asks for a reboot or cold power-off, rerun the same curl command afterward.

## What gets installed

| Path | Purpose |
|---|---|
| `~/.local/share/bryan-gpu-setup/src` | Git clone used to fetch updates |
| `~/.local/lib/bryan-gpu-setup/` | Runtime miner, launcher, GPU helper, terminal app |
| `~/.local/bin/bryan-gpu-setup` | Operator CLI |
| `~/.config/vast-prl-host-miner.env` | Host secrets and miner settings |
| `bryan-gpu-setup-update.timer` | Checks the repo every 6 hours |
| `vast-prl-host-miner.service` | Idle mining watcher |

GPU power/clock fields stay empty. The terminal app probes whatever card is on that host.

## Update service

Each installed host runs `bryan-gpu-setup-update.timer`. When it fires it:

1. Fetches `manifest.json` from the GitHub repo or latest release
2. Compares component versions with `installed.json`
3. Updates only components that changed and that belong to this host's profile
4. Restarts the miner service only if the host is idle
5. Never auto-applies the 170HX driver pin, unlocker, or Vast host daemon
6. Never overwrites the env file

Check it:

```bash
systemctl status bryan-gpu-setup-update.timer
bryan-gpu-setup update --status
bryan-gpu-setup update --check
bryan-gpu-setup update --apply
```

Logs:

```bash
journalctl -u bryan-gpu-setup-update.service -n 50 --no-pager
cat ~/.local/state/bryan-gpu-setup/update.log
```

To pause automatic applies without removing the timer, set `"update_auto": false` in `installed.json`. `--check` still works. `--apply` still forces an update.

## After install

```bash
controlpanel
sudo systemctl start vast-prl-host-miner.service
```

`controlpanel` is installed to `~/.local/bin/controlpanel` and added as a shell alias. Open a new shell, or run `source ~/.bashrc`, then type `controlpanel`.

Keep `~/.local/bin` on `PATH` so `bryan-gpu-setup` resolves.

## Disk full on home

If install fails with `No space left on device` under `~/.local/share`, the home/root filesystem is full. That is common on `rigv3` because Docker data lives on the NVMe while `/home` is still on the small system disk.

Check:

```bash
df -h
du -xh -d1 ~ | sort -h | tail
sudo journalctl --disk-usage
```

Free some space if you can:

```bash
sudo journalctl --vacuum-size=200M
sudo apt-get clean
```

Or install onto the large data disk:

```bash
sudo mkdir -p /var/lib/docker/bryan-gpu-setup
sudo chown "$USER:$USER" /var/lib/docker/bryan-gpu-setup
BRYAN_SETUP_ROOT=/var/lib/docker/bryan-gpu-setup bash <(curl -fsSL https://raw.githubusercontent.com/meteoin/Bryan-GPU-Server-AI-Hosting-And-Mining/main/install.sh)
```
