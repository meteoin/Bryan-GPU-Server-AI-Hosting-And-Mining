# GitHub Curl Installer Plan

This is a design document. The installer, component manifest, and host update service now exist in-tree.

The goal is one GitHub-hosted command that can set up a new NVIDIA host. The installer should detect the GPU, ask which profile to use, and then install only what that machine needs.

- CMP 170HX hosts: existing Vast host bootstrap, then mining + terminal app
- Other NVIDIA hosts, including RTX 5090: mining watcher + terminal app only
- A 5090 must never receive the 170HX driver pin or `cmpunlocker`

## Why this exists

Today the repo is usable, but setup is manual:

- clone the repo
- decide which scripts apply
- run `scripts/ready_170hx_host.sh` only on 170HX
- copy env, systemd, SRBMiner, and the terminal app by hand

That is easy to get wrong on a second machine. The installer should make the first command the only command an operator has to remember.

## Proposed one-liner

Do not use `curl | bash`. That pipe consumes stdin, so the option menu cannot read the keyboard.

Use process substitution so prompts still work:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/<org>/Bryan-GPU-Server-Setup/v1/install.sh)
```

Optional overrides:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/<org>/Bryan-GPU-Server-Setup/v1/install.sh) \
  --profile miner-only \
  --yes
```

Pin the first-install curl URL to a release tag such as `v1`, not `main`. After install, hosts check a versioned release manifest and update only changed components.

The public `install.sh` should stay small. It clones that same tag into a local directory, then execs the real installer from the clone. That way the one-liner always runs a known git revision, not whatever happens to be on `main`.

## Profiles

The installer detects GPUs first, then recommends a profile. It should not force the recommendation.

| Detection | Default profile | Also offered |
|---|---|---|
| CMP 170HX present | `170hx-host` | `miner-only`, quit |
| Other NVIDIA GPU | `miner-only` | quit |
| No NVIDIA GPU | quit | — |

`170hx-host` is the only profile allowed to call `scripts/ready_170hx_host.sh`. That script already fails closed unless it sees CMP 170HX. The installer must still refuse to call it on a non-170HX machine.

`miner-only` is the 5090 path. It installs mining + terminal tooling and leaves the NVIDIA driver stack alone.

## Operator menu

Example on a 170HX host:

```text
Detected: 8x NVIDIA CMP 170HX

  1) 170HX Vast host + idle PRL mining  [recommended]
  2) Mining + terminal only
  3) Quit

Select [1]:
```

Example on a 5090 host:

```text
Detected: 1x NVIDIA GeForce RTX 5090

  1) Mining + terminal only  [recommended]
  2) Quit

Select [1]:
```

All prompts should read from `/dev/tty` so they still work if someone pipes the script by accident.

## Install flow

```text
curl one-liner
  -> tiny public install.sh
      -> clone pinned tag into ~/.local/share/bryan-gpu-setup
      -> detect GPUs with lspci and nvidia-smi when available
      -> show menu
      -> run selected profile
      -> prompt for wallet, machine id, worker, pool, Vast API key
      -> write env, install templated systemd unit, optional nvidia-smi sudoers
      -> print next steps
```

The installer must be rerunnable. After a 170HX driver reboot or unlock power-off, the same curl command should resume from saved state.

## What each path installs

### Common to both profiles

- Ubuntu x86_64, with `curl`, `git`, and `python3`
- Clone this repo at the pinned tag
- Create `~/.config/vast-prl-host-miner.env` from `config/vast-prl-host-miner.env.example`
- Prompt for:
  - `MACHINE_ID`
  - `PRL_WALLET`
  - `WORKER_NAME`
  - `POOL`
  - optional Vast CLI API key
- Download SRBMiner-MULTI `3.6.2` into `~/srbminer`
- Install these scripts to a stable local path such as `~/.local/lib/bryan-gpu-setup/`:
  - `scripts/vast_idle_host_miner.py`
  - `scripts/vast_prl_host_miner_launcher.sh`
  - `scripts/gpu_tuning_helper.py`
  - `scripts/terminal_miner_control.py`
- Template `systemd/vast-prl-host-miner.service` for the current user
- Offer a sudoers drop-in for `/usr/bin/nvidia-smi` if GPU tuning is wanted
- Leave `GPU_POWER_LIMIT`, `GPU_MEMORY_CLOCK`, and `GPU_CORE_CLOCK` empty

GPU tuning stays dynamic. The terminal app and helper probe whatever card is on that host. A 5090 would get its own power and clock ranges. A 170HX would get its own. Those requested values are stored in that host's env file, not shared across machines.

### `170hx-host` only

- Hand off to the existing `scripts/ready_170hx_host.sh`
- Keep that script's reboot, cold power-off, and SSH-key pauses
- After it finishes, install the common mining stack
- Do not skip GPU detection just because the operator selected this profile

Current 170HX-only work that must stay gated:

- pinned `nvidia-open 610.43.02`
- `cmpunlocker`
- optional Docker data-disk migration
- Vast host daemon enrollment

### `miner-only` only

- Skip every 170HX step, even if the wrong menu number is typed
- Do not change NVIDIA driver packages
- Do not clone or run `cmpunlocker`
- Do not install the Vast host daemon
- Do not migrate `/var/lib/docker`

This is the path for a 5090 or any other non-170HX NVIDIA card.

## Versioned releases

Every published GitHub release gets a version, for example `v1.4.0`. That release version is the wrapper. Inside it, each installable part has its own component version so a host can skip pieces that did not change.

Example `manifest.json` published with the release:

```json
{
  "release": "1.4.0",
  "channel": "stable",
  "released_at": "2026-09-17T00:00:00Z",
  "min_installer": "1.0.0",
  "components": {
    "installer": {
      "version": "1.4.0",
      "profiles": ["170hx-host", "miner-only"]
    },
    "miner-watcher": {
      "version": "1.3.1",
      "profiles": ["170hx-host", "miner-only"],
      "files": [
        "scripts/vast_idle_host_miner.py",
        "scripts/vast_prl_host_miner_launcher.sh"
      ]
    },
    "terminal-app": {
      "version": "1.2.0",
      "profiles": ["170hx-host", "miner-only"],
      "files": ["scripts/terminal_miner_control.py"]
    },
    "gpu-tuning": {
      "version": "1.1.0",
      "profiles": ["170hx-host", "miner-only"],
      "files": ["scripts/gpu_tuning_helper.py"]
    },
    "systemd-unit": {
      "version": "1.0.2",
      "profiles": ["170hx-host", "miner-only"],
      "files": ["systemd/vast-prl-host-miner.service"]
    },
    "srbminer": {
      "version": "3.6.2",
      "profiles": ["170hx-host", "miner-only"],
      "kind": "external-binary"
    },
    "170hx-bootstrap": {
      "version": "1.0.0",
      "profiles": ["170hx-host"],
      "auto_update": false,
      "files": ["scripts/ready_170hx_host.sh"]
    }
  }
}
```

Local install state is stored on the host, for example:

```text
~/.local/state/bryan-gpu-setup/installed.json
```

That file records the installed profile, release, and each component version. The updater uses it to decide what is already current.

Rules:

- bump a component version only when that component's files changed
- a release can ship with some component versions unchanged
- `170hx-bootstrap` is tracked, but it is never auto-applied
- host env, wallet, API key, and GPU tuning values are not versioned components and are never overwritten

## Auto-update

After first install, a small timer periodically curls the latest stable manifest and updates only components whose version is newer than local state.

Check URL, pinned to GitHub Releases rather than `main`:

```text
https://github.com/<org>/Bryan-GPU-Server-Setup/releases/latest/download/manifest.json
```

Suggested local timer:

- unit: `bryan-gpu-setup-update.timer`
- interval: every 6 hours, with a randomized delay so hosts do not all hit GitHub at once
- service: `scripts/bootstrap/update.sh`

Update flow:

```text
timer fires
  -> curl manifest.json
  -> compare each component version to installed.json
  -> ignore components not in this host's profile
  -> download only changed files
  -> replace those files atomically
  -> restart only the services that use the changed files
  -> write the new component versions to installed.json
```

Example: release `1.4.0` changes `terminal-app` from `1.1.0` to `1.2.0` and leaves `miner-watcher` at `1.3.1`.

- a 5090 miner-only host downloads `terminal_miner_control.py` only
- it does not restart the mining service
- it does not touch 170HX scripts
- a 170HX host does the same, because `170hx-bootstrap` did not change and is not auto-applied anyway

### What can auto-update

| Component | Auto-update | Restart behavior |
|---|---|---|
| `terminal-app` | yes | none |
| `gpu-tuning` | yes | none, unless the miner is already using the helper on next start |
| `miner-watcher` | yes, if the host is idle | restart `vast-prl-host-miner.service` after swap |
| `installer` / updater scripts | yes | none |
| `systemd-unit` | yes, with template re-apply | `daemon-reload`; restart only if miner-watcher also changed or the unit itself changed |
| `srbminer` | optional, default off | stop miner, replace binary, start only if still idle |
| `170hx-bootstrap` | no | print "update available; rerun installer" |

### What must not auto-update

- NVIDIA drivers
- `cmpunlocker`
- Docker storage layout
- Vast host daemon
- `~/.config/vast-prl-host-miner.env`
- sudoers drop-in contents, unless that component is explicitly bumped and reviewed
- anything on a host whose profile does not include that component

If the machine looks busy to Vast, defer `miner-watcher` and `srbminer` updates. Retry on the next timer run. The terminal app can still update in the background because it is not in the renter path.

### Operator controls

```bash
bryan-gpu-setup update --check
bryan-gpu-setup update --apply
bryan-gpu-setup update --status
```

Config knobs in the local state or env:

- `UPDATE_CHANNEL=stable`
- `UPDATE_AUTO=1`
- `UPDATE_SRBMINER=0`

`--check` is the curl-only path: fetch the manifest, print what would change, exit. The timer can run `--check` and then `--apply` only when there is a delta.

Manual first install stays on a tagged `install.sh`. Ongoing updates follow `releases/latest/download/manifest.json` on the stable channel.

## Repo layout to add

```text
install.sh                          # public curl entrypoint; clone + exec
manifest.json                       # release component versions
scripts/bootstrap/install.sh        # real installer
scripts/bootstrap/detect_gpu.sh     # 170HX vs other NVIDIA
scripts/bootstrap/install_miner.sh  # mining + TUI + systemd
scripts/bootstrap/update.sh         # curl manifest, apply changed components
scripts/ready_170hx_host.sh         # existing; keep its 170HX gate
```

`install.sh` responsibilities:

1. Resolve `BRYAN_SETUP_REF`, defaulting to the latest stable tag
2. Clone `--depth 1 --branch "$REF"`
3. Exec `scripts/bootstrap/install.sh` from that clone
4. Write `installed.json` with profile and component versions
5. Enable the update timer unless the operator passed `--no-auto-update`

## Systemd templating

The current unit is hardcoded to `flyanb` and `/home/flyanb`. The installer must not copy that file unchanged onto a 5090 or any other user account.

Template these fields from the installing user:

- `User=`
- `WorkingDirectory=`
- `Environment=HOME=...`
- `Environment=PATH=...`
- `EnvironmentFile=`
- `ExecStart=`

The installed unit should point at the copied launcher path, not assume the repo checkout lives in the home directory.

## Safety rules

- Default the curl URL and clone to a release tag, not `main`
- Auto-update from GitHub Releases `manifest.json`, not from `main`
- Never commit wallet, Vast API key, public IP, or host passwords
- Prompt for secrets locally; do not pass them through GitHub
- Refuse `ready_170hx_host.sh` unless detection saw CMP 170HX
- Keep the installer idempotent: skip completed steps on rerun
- If this repo is private, the one-liner needs `gh auth` or a token; public hosting is simpler
- GPU tuning sudoers, if installed, must stay limited to `/usr/bin/nvidia-smi`
- Replace updated files atomically, then restart the smallest possible unit
- Do not auto-apply driver, unlock, or Vast host daemon changes
- Do not overwrite the host env file during updates
- Defer miner binary/service restarts while the machine is rented

## Out of scope for v1

- Container mining images
- Per-GPU clock/power fields
- A local product dashboard or Koyeb stats agent
- Automatic Vast listing or pricing
- Windows or non-Ubuntu hosts
- Running the 170HX unlocker "just in case"
- Auto-updating NVIDIA drivers, unlocker, or the Vast host daemon
- Auto-updating SRBMiner unless the operator opts in

## Implementation order

1. GPU detect + wizard stub, with `--profile` and `--yes`. No installs yet.
2. `miner-only` path: checkout, SRBMiner, env wizard, templated systemd, TUI, Vast CLI. Prove this on a non-170HX box first.
3. `170hx-host` path: call existing `ready_170hx_host.sh`, then reuse the miner-only installer.
4. Resume behavior after reboot and cold power-off. Document the one-liner.
5. Add `manifest.json`, `installed.json`, and `scripts/bootstrap/update.sh`.
6. Add the systemd timer that curls the latest stable manifest and applies only changed components.
7. Tag `v1` and only then publish the curl command.

The first useful deliverable is the miner-only installer. That is what a 5090 system needs, and it is also the second half of the 170HX path. Auto-update should land after a host can install cleanly, not before.

## Acceptance checks

Reviewers should be able to say yes to all of these before implementation starts:

- [ ] A 5090 host cannot run `cmpunlocker` or the pinned 170HX driver from this installer
- [ ] A 170HX host can still use the existing bootstrap, including reboot resume
- [ ] The first command is a single curl/bash line against a tagged GitHub file
- [ ] The menu works on a real TTY
- [ ] Mining + terminal app can be installed without becoming a Vast host
- [ ] The systemd unit is valid for users other than `flyanb`
- [ ] Wallet and API key stay on the machine, not in the repo
- [ ] GPU PL / MCLK / CCLK remain probed per host, not copied from the 170HX box
- [ ] Releases publish a `manifest.json` with per-component versions
- [ ] The updater curls that manifest and skips components whose version is unchanged
- [ ] A terminal-app-only release does not restart the miner
- [ ] A 5090 host never downloads or applies `170hx-bootstrap`
- [ ] Miner/service updates wait if the host is rented
- [ ] Host env files are not overwritten by updates

## Open questions

1. Should the published one-liner target a public repo, or stay private with a token?
2. Should `170hx-host` always include mining, or should Vast-host-only remain a third profile?
3. Should the installer enable `vast-prl-host-miner.service` immediately, or leave that as a printed next step?
4. Where should the cloned repo live on disk: `~/.local/share/bryan-gpu-setup` or `/opt/bryan-gpu-setup`?
5. For miner-only hosts, is Vast CLI login required during install, or can that wait until the watcher is enabled?
6. Should auto-update default on, or default to check-only until the operator opts in?
7. Is every 6 hours the right check interval, or is daily enough?
