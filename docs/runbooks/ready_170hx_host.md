# 170HX Host Bootstrap Script

`scripts/ready_170hx_host.sh` automates the Bryan runbook for CMP 170HX hosts and is designed to be rerun safely after:

- the required NVIDIA driver reboot
- the required `cmpunlocker` cold power-off

## What it does

- validates Ubuntu `24.04.x`, `x86_64`, Secure Boot disabled, and CMP 170HX visibility
- installs base packages, Docker, the NVIDIA Ubuntu `24.04` repo, and the pinned `610.43.02` driver
- installs the Vast CLI with `pipx`
- clones and applies `cmpunlocker`
- optionally migrates Docker storage to a dedicated XFS data disk
- pauses to let the operator set up SSH key login, then disables SSH password auth after confirmation
- stops at the Vast host enrollment handoff by default so the installer can be run manually
- optionally sets the Vast host API key
- stops immediately on failure and writes a summary with the failed step, command, exit code, and log path
- skips already-satisfied steps and records the skip reason in `run.log`

## Where it stores state

By default the script writes state and logs to:

```bash
/var/tmp/170hx-ready/<hostname>/
```

That directory contains:

- `state.env`
- `logs/`
- `run.log`
- `last_failure.txt`

## Example: fresh host, no storage migration yet

```bash
chmod +x ./scripts/ready_170hx_host.sh
./scripts/ready_170hx_host.sh
```

The first run will likely stop after installing the pinned driver and tell you to reboot.

After reboot, rerun the same command:

```bash
./scripts/ready_170hx_host.sh
```

It will resume, skip completed steps, and continue into the unlock flow.

If `cmpunlocker` is applied successfully, it will stop and tell you to do a cold power-off.

After powering the host back on, rerun it again:

```bash
./scripts/ready_170hx_host.sh
```

If password SSH is still enabled at that point, the script will stop and print:

- the local `ssh-keygen` command with an empty passphrase (`-N ''`)
- the command to print the public key
- the exact server path where the public key must be appended: `~/.ssh/authorized_keys`

After you test key login from your own machine, rerun with:

```bash
./scripts/ready_170hx_host.sh --confirm-ssh-key-auth
```

That rerun lets the script disable password authentication and continue toward the Vast onboarding handoff.

## Example: include the Vast host installer command

By default, the script stops before running the Vast installer and tells the operator to fetch the command from the Vast setup page.

If you want the script to run the installer anyway, use:

```bash
./scripts/ready_170hx_host.sh \
  --run-vast-installer \
  --vast-installer-cmd 'PASTE_THE_VAST_HOST_INSTALLER_COMMAND_HERE'
```

If quoting the one-line command is annoying, put it in a file and use:

```bash
./scripts/ready_170hx_host.sh --vast-installer-cmd-file ./vast_installer_cmd.txt
```

## Example: include Docker data-disk migration

```bash
./scripts/ready_170hx_host.sh \
  --data-disk /dev/nvme0n1
```

This follows the same XFS + `pquota` layout used in the Bryan runbook.

## Example: fully automated disruptive steps

```bash
./scripts/ready_170hx_host.sh \
  --auto-reboot \
  --auto-poweroff \
  --data-disk /dev/nvme0n1 \
  --vast-installer-cmd-file ./vast_installer_cmd.txt
```

Use this mode only if on-site power control and remote access are already dependable.

## Failure handling

If a step fails, the script writes:

```bash
/var/tmp/170hx-ready/<hostname>/last_failure.txt
```

That file includes:

- failing step name
- full command that failed
- exit code
- log file path
- tail of the failing log

## Good first target

Use this on `rigv4` first before rolling it onto any larger host.

## Important

If you do not pass `--skip-vast-host`, the script will now stop at the Vast onboarding handoff and tell the operator to copy the generated install command from the Vast setup page.

That is because a machine can have:

- working Ubuntu, driver, and unlock setup
- but still not be enrolled as a Vast host

If that step is skipped, the machine will not appear in `vastai show machines`.

If you explicitly want the script to run the installer command too, use `--run-vast-installer` together with either `--vast-installer-cmd` or `--vast-installer-cmd-file`.
