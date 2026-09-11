# Glossary (this job only)

Plain meanings for terms in the pitch deck and security briefing. "In this job" is how you should use the word with Bryan.

---

## Hardware

**G481-HA0**  
Gigabyte 4U GPU server. Bryan has two. Dual Xeon Platinum CPUs, **384 GB** RAM, up to many PCIe GPU slots, dual **10GbE** NICs, dedicated **IPMI**.

**Dual Platinum**  
Two Intel Xeon Platinum CPUs in one chassis. Both must be alive on this model or part of the GPU fabric dies.

**Dual-root**  
PCIe GPUs are split across the two CPUs, not all hung off one socket. Inventory and NUMA matter.

**NUMA**  
Memory and PCIe devices sit nearer one CPU than the other. Wrong placement can make some GPUs slow or missing.

**CMP 170HX**  
NVIDIA mining GPU on **GA100** silicon (same family as A100). Firmware-locked until community unlock. List it as CMP 170HX, not A100.

**GA100 / A100**  
Datacenter GPU die / product. 170HX is related silicon with mining limits. Renters searching "A100" will not (and should not) see a 170HX listed as one.

**Unlock (170HX)**  
Community driver/firmware path that restores compute and VRAM geometry. Experimental. Must **persist** across reboot before we list.

**Persist**  
Still true after a reboot. For 170HX: nvidia-smi and Docker GPU still look right after reboot.

**VRAM**  
GPU memory. Stock 170HX is 8 GB or 10 GB. Unlock can report 64 GB or 40 GB. Listing must match what the driver reports.

**PCIe / Gen1 x4 / Gen3 x16**  
Slot and link speed between CPU and GPU. G481 slots are Gen3 x16 physically. Stock 170HX is firmware-locked to Gen1 x4 (~1 GB/s). Unlock currently raises that to Gen2. Copies to/from GPU stay slower than a real A100.

**PSU**  
Power supply. 170HX is ~250-300W. **gpu-burn** will show if the chassis or cooling cannot hold load.

**10GbE / 2.5GbE / 10G uplink**  
Network port speed. G481 has 10 gigabit Ethernet. UXG-Fiber has 10G and slower 2.5G ports. Plug servers into **10G**, not the 2.5G switch ports.

**SFP+**  
Fiber/module cage on the gateway (10G). Typical fiber WAN or 10G LAN link.

**NIC**  
Network card. Rental traffic uses the G481 10GbE NICs. IPMI uses a separate management NIC.

**PCI ID**  
Hardware identity of each GPU in `lspci`. Used in inventory to tell 8 GB vs 10 GB 170HX variants apart.

**BIOS / POST**  
Firmware that starts the machine. If it will not POST, that is on-site hands, not remote Ubuntu work.

---

## Edge / UniFi / security

**UniFi**  
Ubiquiti's network product line (controller + gear). Bryan's new router is in this family.

**UXG-Fiber / UniFi Gateway Fiber**  
The actual router: compact 10G security gateway. Zone firewall, NAT, VPN, IDS/IPS. No built-in Wi-Fi. Needs a UniFi controller (Cloud Key, UniFi Network Server, or official hosting).

**Edge**  
The box that faces the internet. Here: UXG-Fiber.

**WAN**  
Internet side of the gateway.

**LAN**  
Inside the site (servers, Wi-Fi, IPMI).

**Public IP**  
Address the internet can reach. Vast renters need this (or 1:1 NAT) so inbound ports work.

**CGNAT**  
Carrier-grade NAT: many customers share one public IP. Inbound Vast ports usually **fail**. Ask Bryan this first.

**VLAN**  
A separate LAN on the same cables. We want at least **Rental** (GPU NICs) and **Mgmt** (IPMI, SSH).

**Zone / zone-based firewall**  
UniFi groups networks (WAN, Rental, Mgmt, VPN) and sets allow/deny between them. Default between zones: **deny**.

**Default deny**  
Nothing is allowed unless we write a rule. Opposite of "open everything then block a few ports."

**DNAT / port forward**  
Gateway maps public `IP:port` to an internal host port. Vast needs a **TCP range per chassis**, not "all ports."

**NAT**  
Sharing/translating addresses. WAN NAT is normal. Do not NAT IPMI onto the internet.

**UPnP**  
Devices open ports on the router by themselves. **Off** here. Vast ports are explicit DNAT.

**IDS/IPS**  
Intrusion detection / prevention on the gateway. UXG-Fiber can run this at about **5 Gbps**. Turn **on** for this site.

**Layer 7 firewall**  
Rules that can match apps/domains, not just ports. UniFi has this; we still start with zones and ports.

**UFW**  
Ubuntu host firewall. Allow Vast range + SSH from Mgmt. Deny the rest on the host, in addition to UniFi.

**SSH**  
Remote shell. Keys only. Not on public port 22. You reach it after **VPN**.

**VPN**  
Encrypted admin path into Mgmt (WireGuard, UniFi Teleport, or similar). How you work remotely without exposing SSH/IPMI.

**Teleport (UniFi)**  
Ubiquiti's zero-config VPN into the gateway. One option for your admin path. Not Cloudflare.

**WireGuard**  
Common VPN protocol. UXG-Fiber supports it.

**IPMI / BMC**  
Lights-out management on the server (here **AST2500**). Power, console, firmware, even if Ubuntu is down. Must stay on Mgmt, never WAN.

**AST2500**  
Aspeed chip that implements IPMI on the G481.

**Pen test**  
Paid attack simulation. **Not** this job. You do an operator review.

---

## Vast / Docker / CUDA

**Vast.ai**  
GPU rental marketplace. Bryan is a **host** (sells time). Renters bring their own containers.

**Host / host daemon**  
Software Vast installs on the Ubuntu box. It launches renter Docker containers and maps ports. Vast owns renter isolation.

**Renter**  
Customer who pays for GPU time. Untrusted. They get a container, not host SSH or IPMI.

**List / listing / offer**  
Publishing the machine on Vast at a price. Last step, after smoke + **gpu-burn** + ports.

**Self-test**  
Vast's own check before/during listing.

**Verification**  
Vast badge for reliability/bandwidth. Mining-class cards may **never** get it. List unverified first.

**Dedicated while rented**  
No extra product, model servers, or heavy backends on the GPU host during a rental.

**Docker**  
Container runtime. Vast renters run here. Our smoke and gpu-burn also run here.

**NVIDIA Container Toolkit / `--gpus all`**  
Lets Docker see NVIDIA GPUs. Required for Vast and for gpu-burn.

**CUDA / CUDA 12**  
NVIDIA compute API. On the **host** we install a driver new enough for CUDA 12 **containers**. We do not install the renter's PyTorch on bare metal.

**NVIDIA driver**  
Kernel driver for the GPU. `nvidia-smi` talks to it.

**nvidia-smi**  
CLI that shows GPUs, VRAM, temp, processes. Proves the card is **visible**. Does not prove it survives load.

**gpu-burn**  
Docker CUDA stress test (`oguzpastirmaci/gpu-burn`). Runs the GPU hard. Proves load, heat, PSU. Only on an unrented host, after persist, before list.

**Smoke test**  
Short "does it work at all" check (smi in Docker). Burn is the longer load check.

**Container vs host**  
Host = Ubuntu on the G481. Container = isolated app (Vast renter, or gpu-burn). CUDA toolkit for training lives in the renter container.

**Webhook**  
HTTP ping on down/recover. How we alert Bryan without a second control plane.

---

## Process words in the deck

**Bootstrap**  
First install on a box (Ubuntu, Docker, driver). Happens once. Then scripts **clone**.

**Idempotent**  
Safe to run the Python setup again. Same end state.

**Clone box B**  
Replay box A's scripts on the second G481.

**Admin plane / control plane**  
Optional later: one UI for health of both hosts. Not required to go live. Never in front of renter ports.

**Reverse proxy / Cloudflare in front**  
Putting Cloudflare (or similar) between the internet and Vast ports. **Wrong** for renters. Breaks SSH/Jupyter mapping. VPN/tunnel is only for **admin**.

**GPU Lab**  
Your old product: you owned the marketplace and customer path. Here Vast owns that. What transfers is host Docker, health, overload.

**Inventory**  
First pass: GPU count/variant, sockets, NICs, IPMI, disks. Before installing anything clever.

**Runbook**  
Short "if X, do Y" notes Bryan can use when you are offline.
