# Bryan Ubuntu 24.04.4 Vast Setup Runbook

This runbook documents the setup sequence we prepared for Bryan's Ubuntu host, excluding the unrelated `anydesk` package issue.

Target machine state this runbook assumes:

- Ubuntu `24.04.4 LTS`
- Architecture: `x86_64`
- Secure Boot: disabled
- GPUs detected on PCIe as NVIDIA `GA100 [CMP 170HX]`

Use this on one host first before repeating it on any second machine.

---

## 1. Pre-checks

Confirm the host matches the expected prerequisites.

```bash
uname -m
```

Expected:

- `x86_64`

```bash
source /etc/os-release && echo "$PRETTY_NAME"
```

Expected:

- `Ubuntu 24.04.4 LTS`

```bash
mokutil --sb-state || true
```

Expected:

- `SecureBoot disabled`

```bash
lspci -nn | grep -Ei 'NVIDIA|3D|VGA'
```

Expected:

- the onboard ASPEED graphics entry
- NVIDIA `GA100 [CMP 170HX]` entries for the installed CMP cards

---

## 2. Install required base packages

Update package indexes:

```bash
sudo apt update
```

Install the packages needed for Python tooling, kernel headers, build tooling, and the later unlock flow:

```bash
sudo apt install -y python3 python3-pip git curl patch build-essential mokutil linux-headers-$(uname -r)
```

This step should complete successfully before moving on.

---

## 3. Add NVIDIA's Ubuntu 24.04 repository

Download the CUDA/NVIDIA repo keyring for Ubuntu 24.04:

```bash
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
```

Install the keyring:

```bash
sudo dpkg -i cuda-keyring_1.1-1_all.deb
```

Refresh package indexes:

```bash
sudo apt update
```

---

## 4. Check the available `nvidia-open` versions

Before installing the driver, inspect the exact versions exposed by the NVIDIA repo:

```bash
apt-cache madison nvidia-open
```

We were targeting the `610.43.0x` family because that is the driver family the CMP unlocker documentation calls out.

If you see `610.43.02-1ubuntu1`, continue with the exact install below.

---

## 5. Install the pinned NVIDIA open driver

Install the NVIDIA pinning package:

```bash
sudo apt install -y nvidia-driver-pinning-610.43.02
```

Install the exact open driver build:

```bash
sudo apt install -y nvidia-open=610.43.02-1ubuntu1
```

Reboot after the driver install:

```bash
sudo reboot
```

---

## 6. Verify the NVIDIA driver after reboot

After the machine comes back, confirm the driver version and GPU visibility:

```bash
nvidia-smi --query-gpu=driver_version,name,memory.total --format=csv
```

```bash
modinfo -F version nvidia
```

Expected:

- driver version in the `610.43.02` line
- all CMP 170HX GPUs visible

Do not proceed to Vast host setup or CMP unlocking until this is clean.

---

## 7. Install the Vast CLI with `pipx`

Ubuntu 24.04 uses an externally managed Python environment, so a plain `pip install vastai` will fail unless you force system-package overrides.

Use `pipx` instead.

Install `pipx`:

```bash
sudo apt install -y pipx
```

Ensure the `pipx` binary path is available:

```bash
pipx ensurepath
```

Open a new shell or reload your shell config. If you need an immediate fix in the current session, run:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Install the Vast CLI:

```bash
pipx install vastai
```

Confirm it responds:

```bash
vastai --help
```

If the command is still not found, use:

```bash
~/.local/bin/vastai --help
```

---

## 8. Recommended order change

After validating this host in practice, the better sequence for CMP 170HX on Ubuntu `24.04.4` is:

1. install the compatible NVIDIA open driver
2. apply and verify `cmpunlocker`
3. only then install and register the Vast host daemon

This matters because Vast did not correctly identify the GPUs before the unlock was applied and verified. After the unlock, Vast correctly recognized the machine as `8x CMP 170HX`.

---

## 9. Apply the CMP unlock before Vast setup

Only do this after:

- the stock NVIDIA driver is stable
- `nvidia-smi` works
- the host is confirmed to be using `nvidia-open 610.43.02`

Clone the unlocker repo:

```bash
git clone https://github.com/amoghmunikote/cmpunlocker.git
```

Enter the repo:

```bash
cd cmpunlocker
```

Run the installer for the 10 GB CMP 170HX profile:

```bash
sudo ./install.sh --profile=10gb
```

If the installer reports success and recommends a cold reboot, shut the machine down fully:

```bash
sudo shutdown -h now
```

Power the machine back on and reconnect over SSH.

Verify the unlock:

```bash
cd ~/cmpunlocker
```

```bash
sudo ./verify.sh
```

```bash
nvidia-smi
```

```bash
nvidia-smi --query-gpu=name,memory.total,pcie.link.gen.current,pcie.link.gen.max --format=csv
```

Expected successful result on Bryan's host:

- all 8 GPUs show `NVIDIA CMP 170HX`
- all 8 GPUs show about `40960 MiB`
- PCIe query shows `2,2`
- `verify.sh` reports `OK` for every GPU

This confirmed that the unlock persisted correctly across reboot on the tested machine.

---

## 10. Prepare the Vast hosting account

Do this in the Vast web interface:

- create or confirm a separate Vast hosting account
- accept the hosting agreement
- open the host setup page for the machine setup flow

Do not use the same account for client renting and hosting.

---

## 11. Install the Vast host software

On the host setup page, Vast provides a generated one-line installer command.

Run the exact command shown by Vast on that page.

We intentionally did not hardcode that command here because the host setup flow can provide account-specific or current installer details.

---

## 12. Verify the host services

Check Docker:

```bash
sudo systemctl status docker --no-pager
```

Check the Vast host service:

```bash
sudo systemctl status vastai --no-pager
```

Both services should be active before continuing.

---

## 13. Migrate Docker storage to a dedicated data SSD

Bryan later installed a separate large NVMe SSD for renter data. The correct layout for this host is:

- keep Ubuntu and host operations on the system disk
- move Docker storage to the dedicated data SSD
- let Vast consume that Docker-backed storage pool for renter images and instance disk

On the tested host, the problem was not the Ubuntu install itself. The problem was that `/var/lib/docker` was mounted from a small loopback-backed XFS file:

```bash
findmnt /var/lib/docker
mount | grep ' /var/lib/docker '
cat /etc/fstab
```

The pre-migration state looked like:

- `/var/lib/docker` mounted from `/dev/loop5`
- `/etc/fstab` contained:

```fstab
/var/lib/docker-loop.xfs /var/lib/docker/ xfs loop,rw,auto,pquota 0 0
```

The host also had a blank dedicated data SSD available as `nvme0n1`.

### 13.1 Prepare the SSD

Install XFS tools if needed:

```bash
sudo apt install -y xfsprogs
```

Partition the SSD:

```bash
sudo parted /dev/nvme0n1 --script mklabel gpt mkpart primary xfs 1MiB 100%
```

Format it as XFS:

```bash
sudo mkfs.xfs -f /dev/nvme0n1p1
```

Create a temporary mount:

```bash
sudo mkdir -p /mnt/vast-data
sudo mount /dev/nvme0n1p1 /mnt/vast-data
```

Verify that XFS `ftype=1` is present:

```bash
sudo xfs_info /mnt/vast-data | grep ftype
```

Expected result:

- `ftype=1`

### 13.2 Copy the Docker data and stop services

Do an initial copy while services are still up:

```bash
sudo rsync -aHAXx /var/lib/docker/ /mnt/vast-data/
```

Stop the Vast and container services:

```bash
sudo systemctl stop vastai
sudo systemctl stop docker.service
sudo systemctl stop docker.socket
sudo systemctl stop containerd.service
```

If `docker.service` says it is still triggered by `docker.socket`, that is expected. Stopping the socket resolves it.

Do a final sync after the services are down:

```bash
sudo rsync -aHAXx --delete /var/lib/docker/ /mnt/vast-data/
```

### 13.3 Replace the old loopback mount

Get the UUID of the new SSD partition:

```bash
sudo blkid /dev/nvme0n1p1
```

On Bryan's tested host, the new UUID was:

- `bcf33db4-3a1f-42f7-850f-25c8c3eb0dbc`

Back up `fstab`:

```bash
sudo cp /etc/fstab /etc/fstab.bak
```

Comment out the old loopback Docker mount and replace it with the new SSD mount:

```fstab
# /var/lib/docker-loop.xfs /var/lib/docker/ xfs loop,rw,auto,pquota 0 0
UUID=bcf33db4-3a1f-42f7-850f-25c8c3eb0dbc /var/lib/docker xfs defaults,pquota,nofail 0 2
```

If the host editor is awkward over SSH, this non-interactive edit worked:

```bash
sudo sed -i '\|^/var/lib/docker-loop.xfs /var/lib/docker/ xfs loop,rw,auto,pquota 0 0$| s|^|# |' /etc/fstab
printf '%s\n' 'UUID=bcf33db4-3a1f-42f7-850f-25c8c3eb0dbc /var/lib/docker xfs defaults,pquota,nofail 0 2' | sudo tee -a /etc/fstab
cat /etc/fstab
```

### 13.4 Cut over to the new mount

Reload systemd so it notices the `fstab` change:

```bash
sudo systemctl daemon-reload
```

Swap the live mount:

```bash
sudo umount /mnt/vast-data
sudo umount /var/lib/docker
sudo mount /var/lib/docker
findmnt /var/lib/docker
```

Expected result:

- `/var/lib/docker` mounted from `/dev/nvme0n1p1`

### 13.5 Restart and verify

Bring services back:

```bash
sudo systemctl enable docker.socket
sudo systemctl start containerd
sudo systemctl start docker
sudo systemctl start vastai
```

Verify the Docker storage driver and root:

```bash
sudo docker info | egrep 'Storage Driver|Docker Root Dir|Backing Filesystem'
```

Expected result on Bryan's host:

- `Storage Driver: overlay2`
- `Backing Filesystem: xfs`
- `Docker Root Dir: /var/lib/docker`

Verify the mount and free space:

```bash
findmnt /var/lib/docker
df -h /var/lib/docker
sudo systemctl status docker --no-pager
sudo systemctl status vastai --no-pager
```

Expected post-migration state:

- `/var/lib/docker` mounted from `/dev/nvme0n1p1`
- about `3.6T` free on the data SSD
- both `docker` and `vastai` active

### 13.6 Re-list and re-test on Vast

After the storage cutover, the machine had to be re-listed before self-test could run a diagnostic instance.

Check listing state:

```bash
vastai show machines
vastai search offers 'machine_id=148390 rentable=any rented=any verified=any'
```

If there are no visible offers, create or update the listing:

```bash
vastai list machine 148390 -g 0.15 -m 1 -r 0 -e "09/06/2026"
```

Then verify:

```bash
vastai search offers 'machine_id=148390 verified=any'
vastai self-test machine 148390
```

On Bryan's tested host after migration:

- Vast saw about `3352 GB` of disk
- the machine showed searchable `1x`, `2x`, `4x`, and `8x` offers again
- self-test moved past the storage/listing issue and failed only on PCIe bandwidth

Important cleanup note:

- do not delete `/var/lib/docker-loop.xfs` until Docker, Vast, and self-test are all confirmed healthy

---

## 14. Configure the Vast host port range and public IP

After the Vast host daemon is installed, confirm the host-side port range it is actually advertising.

On Bryan's machine, the daemon initially used `4000-4099`, even though a different range had been discussed earlier.

Check the current daemon-advertised range:

```bash
sudo grep -R "host_port_range\|port_range" /var/lib/vastai_kaalia/kaalia.log | tail -n 20
```

If needed, set the explicit range used by Vast:

```bash
sudo bash -c 'echo -n "4000-4199" > /var/lib/vastai_kaalia/host_port_range'
```

Set the public IP explicitly:

```bash
sudo bash -c 'echo -n "71.218.106.223" > /var/lib/vastai_kaalia/host_ipaddr'
```

Restart the daemon:

```bash
sudo systemctl restart vastai
```

Verify the daemon picked up the new settings:

```bash
sudo grep -R "host_port_range\|port_range" /var/lib/vastai_kaalia/kaalia.log | tail -n 20
```

Expected result:

- `host_port_range: 4000 4199`
- `port_range: 4000-4199`
- `public_ipaddr: 71.218.106.223`

---

## 15. Configure UniFi / router port forwarding

The working configuration for Bryan's machine was a dedicated WAN port-forward rule matching the Vast host daemon range.

Create a new port-forwarding rule in UniFi:

- Policy type: `Port Forwarding`
- Name: `rigv3` or `rigv3-vast`
- WAN interface: `WAN1`
- WAN IP address: `71.218.106.223`
- WAN port: `4000-4199`
- Source / From: `Any`
- Forward IP address: `192.168.1.174`
- Forward port: `4000-4199`
- Protocol: `TCP/UDP` worked in practice, though Vast self-test mainly needs `TCP`

Important:

- do not rely only on an `Internet In` firewall rule
- do not use `Internet Out` for this
- the key working piece is the WAN `Port Forwarding` / DNAT rule

If multiple hosts share the same public IP, each host must use a unique external port range.

---

## 16. Configure VPN-first admin access

For Bryan's site, the safer remote admin path is:

1. connect to the UniFi WireGuard VPN
2. SSH to the host over its LAN IP
3. pause or remove any public WAN SSH port-forward

This was tested from France to the client's USA site and worked after the VPN settings and UniFi changes were applied.

### 16.1 UniFi VPN server

The working UniFi VPN setup used:

- VPN type: `WireGuard`
- Server name: `One-Click VPN`
- Public address: `71.218.106.223`
- Port: `51820`
- VPN subnet: `192.168.7.0/24`
- VPN gateway: `192.168.7.1`

In UniFi:

- go to `Settings -> VPN`
- open the existing WireGuard VPN server
- add a client profile for the remote administrator
- export the client configuration

### 16.2 WireGuard client on the admin machine

On the admin laptop:

- import the WireGuard profile
- connect the tunnel
- confirm the interface receives an address such as `192.168.7.2/32`

The tested client configuration used:

- local client tunnel IP: `192.168.7.2/32`
- endpoint: `71.218.106.223:51820`
- DNS: `192.168.7.1`
- `AllowedIPs = 0.0.0.0/0`

### 16.3 Validation from the remote admin side

After the UniFi changes were applied, the following checks succeeded from the remote admin machine:

```bash
ping -c 3 192.168.7.1
```

```bash
ping -c 3 192.168.1.174
```

```bash
ssh flyanb@192.168.1.174
```

Successful result means:

- the WireGuard tunnel is live
- the admin machine can reach the client's LAN
- the Ubuntu host can be administered without public SSH exposure

### 16.4 Public SSH port-forward removal

Before changing the public SSH rule:

1. connect to the VPN
2. open a successful SSH session to `flyanb@192.168.1.174`
3. keep that session open

Then in UniFi:

- pause the public WAN SSH port-forward on port `22`
- verify that a fresh VPN-based SSH connection still works

This was confirmed successfully on Bryan's host.

### 16.5 Host-side SSH posture

Preferred posture after key login is proven:

- `PermitRootLogin no`
- `PubkeyAuthentication yes`
- `PasswordAuthentication no`

The `rigv3` cutover process and an admin-laptop script are in:

- `docs/runbooks/SSH_Key_Only_Access.md`
- `scripts/setup_ssh_key_access.sh`

Do not disable password SSH until this test succeeds from the laptop:

```bash
ssh -i ~/.ssh/id_ed25519_rigv3 -o IdentitiesOnly=yes -o PasswordAuthentication=no flyanb@192.168.1.174
```

---

## 17. Configure the Vast CLI with the host API key

Set the API key:

```bash
vastai set api-key <YOUR_HOST_API_KEY>
```

List hosted machines:

```bash
vastai show machines
```

This confirms the CLI is authenticated against the correct account.

---

## 18. Run the Vast self-test

After the machine has been added and has a machine ID, run:

```bash
vastai self-test machine <MACHINE_ID>
```

If you need the relaxed form:

```bash
vastai self-test machine <MACHINE_ID> --ignore-requirements
```

Use this to validate driver setup, networking, ports, and general rentability.

If self-test reports that the progress endpoint is unreachable, confirm:

- the Vast daemon and router are using the same external range
- the router is forwarding that exact range to the host LAN IP
- the failure is not caused by a stale earlier range such as `4000-4099`

---

## 19. Confirm the listing appears in offers

Search for the machine by ID:

```bash
vastai search offers 'machine_id=<MACHINE_ID> verified=any'
```

This verifies that the listing is visible from the marketplace side.

---

## 20. Practical stop conditions

Stop and reassess if any of the following happen:

- `apt-cache madison nvidia-open` does not show the expected `610.43.0x` line
- `nvidia-open=610.43.02-1ubuntu1` cannot be installed cleanly
- `nvidia-smi` fails after reboot
- not all CMP cards appear after the driver install
- the Vast host service does not come up
- the self-test fails on core driver or networking checks
- the router forwards a different range than the Vast daemon advertises
- the unlock does not persist across reboot
- the machine becomes unstable under GPU load
- the VPN tunnel connects but cannot reach either `192.168.7.1` or the host LAN IP
- public SSH remains exposed after VPN access has been proven

---

## 21. Current known limitations

Bryan's tested host reached a usable and searchable Vast state, and the earlier Docker loopback storage limitation was fixed by moving `/var/lib/docker` onto the dedicated NVMe SSD. The important remaining caveats are:

- Vast status remained `unverified`
- reliability improved to about `95.9%` after the later stability and storage changes
- PCIe bandwidth remained about `1.6 GB/s`, below Vast's stricter self-test preflight target
- the machine advertises correctly and shows searchable `2x`, `4x`, and `8x` CMP 170HX offers, but verification may still lag behind operational availability
- Vast now sees about `3352 GB` of disk on the host after the SSD migration

Operational meaning:

- the machine is working well enough to appear in Vast search results
- GPU detection, CUDA, and direct port mapping are functioning
- renter disk capacity is now in a much healthier state
- verification and polish are still limited primarily by PCIe bandwidth and verification history

Recommended follow-up:

- leave the host online and stable to improve reliability
- avoid unnecessary reboots or daemon restarts
- rerun self-test after more stable uptime
- investigate BIOS, riser, slot, or motherboard layout factors if improving PCIe bandwidth matters

---

## 22. Recommended execution order

Follow the runbook in this order:

1. Pre-checks
2. Base packages
3. NVIDIA repo
4. Driver version check
5. Pinned driver install
6. Reboot and verify
7. CMP unlock install
8. Cold reboot and unlock verification
9. Vast CLI install
10. Vast host account setup
11. Vast host installer
12. Service verification
13. If a dedicated data SSD is installed, move `/var/lib/docker` off the loopback file and onto the SSD
14. Vast port range + public IP verification
15. Router port-forward rule
16. VPN-first admin access
17. CLI authentication
18. Self-test
19. Listing confirmation

This reflects the tested order that allowed Vast to correctly identify Bryan's unlocked CMP 170HX GPUs.
