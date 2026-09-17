# Bryan GPU Server Setup

This repo contains the runbooks, scripts, and deployment assets for Bryan's Vast.ai GPU host setup and the host-native PRL mining flow.

## Layout

- `docs/architecture/`
  - project context, architecture, glossary, security notes, and implementation planning
- `docs/runbooks/`
  - operator runbooks for host bring-up and recovery
- `docs/mining/`
  - mining-specific docs, container experiments, and the terminal control plan
- `scripts/`
  - executable host automation scripts and watchers
- `scripts/bootstrap/`
  - curl installer, GPU detection, and the host update service
- `config/`
  - example runtime config files
- `systemd/`
  - service unit files
- `containers/`
  - Docker-based miner experiments

## Install

On a new NVIDIA host:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/meteoin/Bryan-GPU-Server-AI-Hosting-And-Mining/main/install.sh)
```

That command detects CMP 170HX vs other NVIDIA GPUs, then installs either the 170HX Vast bootstrap plus mining, or mining + terminal only. After install, `bryan-gpu-setup-update.timer` checks the repo every 6 hours and applies only components whose version changed.

```bash
bryan-gpu-setup update --status
bryan-gpu-setup update --check
bryan-gpu-setup update --apply
```

See `docs/runbooks/GitHub_Curl_Installer.md` for the operator flow.

## Most important files

- `scripts/vast_idle_host_miner.py`
  - production watcher for starting or stopping the host-native miner
- `scripts/terminal_miner_control.py`
  - terminal dashboard for editing config, viewing GPU and watcher status, and tailing miner logs
- `scripts/gpu_tuning_helper.py`
  - probes NVIDIA tuning support, validates requested PL/MCLK/CCLK values, and safely reapplies supported settings
- `scripts/vast_prl_host_miner_launcher.sh`
  - converts env config into watcher arguments
- `config/vast-prl-host-miner.env.example`
  - example runtime configuration
- `systemd/vast-prl-host-miner.service`
  - watcher service unit
- `docs/mining/Host_Native_PRL_Mining.md`
  - main mining setup and operating guide
- `docs/mining/Terminal_Miner_Control_Plan.md`
  - terminal UI feasibility and implementation plan

## Current preferred path

The preferred live path is the host-native SRBMiner flow, not the container mining flow, because Bryan's tested `rigv4` host did not reliably expose GPUs inside the mining containers.

## Terminal control app

Run the first terminal dashboard version with:

```bash
python3 ./scripts/terminal_miner_control.py
```

By default it uses `~/.config/vast-prl-host-miner.env` if present, otherwise it falls back to `config/vast-prl-host-miner.env.example`.

## GPU tuning behavior

If `GPU_POWER_LIMIT`, `GPU_MEMORY_CLOCK`, or `GPU_CORE_CLOCK` are set in the env file, the launcher now calls `scripts/gpu_tuning_helper.py` before starting the watcher. The helper:

- probes whether the installed NVIDIA driver and GPU expose each control
- validates requested values against supported ranges or supported clocks when available
- applies only the supported settings
- writes a state snapshot to `STATE_DIR/gpu_tuning_state.json` for the terminal dashboard

Important: automated GPU tuning needs non-interactive root access to `nvidia-smi`. On `rigv4`, the fix was a sudoers drop-in for `flyanb`:

```sudoers
flyanb ALL=(root) NOPASSWD: /usr/bin/nvidia-smi
```

Without that rule, the dashboard can show a requested `GPU PL` value while the actual cards remain at the default NVIDIA limit.
