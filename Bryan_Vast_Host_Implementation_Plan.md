# Bryan Vast.ai Host Implementation Plan

This document expands the existing architecture deck, glossary, and security briefing into one operational plan for Bryan's actual target state:

- Bryan wants to host GPU machines on Vast.ai so third parties can rent them for LLM and other CUDA workloads.
- The NVIDIA CMP 170HX cards were originally reserved for BTC mining, but Bryan now wants them exposed as usable compute hardware if the `cmpunlocker` path is stable enough.
- The edge is UniFi / Ubiquiti, so the rental network, management network, VPN access, and WAN exposure need to be designed around that reality.

This is an operator plan, not a promise that every unlock path or every rented workload will succeed on day one.

---

## 1. Updated target state

The site should end up with:

1. One or two Gigabyte G481-HA0 hosts running Ubuntu, Docker, NVIDIA drivers, and Vast host software.
2. Vast-compatible inbound networking with a real public IP, explicit open port ranges, and direct renter access to the mapped ports.
3. A management path that is private: VPN first, then SSH and IPMI, with no public management exposure.
4. CMP 170HX GPUs available for compute only if the unlock survives reboot, survives burn-in, and passes the Vast self-test gates that matter for rentability.
5. No local product stack on the rental machines while they are rented. Health/ops telemetry can leave the box over outbound HTTPS.

---

## 2. What Vast.ai changes about the design

Vast is not just "Docker on a GPU server." It is a marketplace with host-side obligations:

- Hosts are responsible for Ubuntu setup, NVIDIA drivers, router port exposure, Vast daemon install, and troubleshooting driver/network/GPU issues.
- Vast expects the machine to stay available and fully functional for the full rental contract once listed and rented.
- Vast requires a separate hosting account from any client/renter account.
- Vast expects direct connectivity to the machine for common client workflows, so port handling at the router matters.
- Vast recommends testing your own machine either with a separate client account or with the Vast CLI before trusting a public listing.

Operational implication:

- We should treat "listing" as the last step, not the first.
- We should keep the hosts dedicated while rented.
- We should avoid any background services on the rental hosts that are not necessary for hosting, monitoring, or recovery.

Reference docs:

- Vast Hosting Overview: <https://docs.vast.ai/host/hosting-overview>
- Vast How to Self-Test: <https://docs.vast.ai/host/how-to-self-test>
- Vast Verification Stages: <https://docs.vast.ai/host/verification-stages>

---

## 3. CMP 170HX unlock: what it means for this job

The `amoghmunikote/cmpunlocker` repository is the relevant community path Bryan pointed to. As of the current README:

- It targets the NVIDIA CMP 170HX on GA100 silicon.
- It targets `nvidia-open 610.43.0x` and patches open kernel modules rather than installing the full NVIDIA userspace package itself.
- It requires Linux x86-64, root access, matching kernel headers, Secure Boot disabled, and network access on first install.
- It auto-detects 8 GB vs 10 GB cards and maps them to different unlock geometries.
- The published install flow may require a cold reboot if the modules do not hot-reload cleanly or if memory still reports stock size.
- The README claims persistence across reboot once the patched modules are in place.

The repo's stated geometry mapping is:

| Physical card | Reported unlock geometry |
|---|---|
| 8 GB CMP 170HX | 64 GB |
| 10 GB CMP 170HX | 40 GB |

Important caution for Bryan:

- This is still a community unlock path, not an official NVIDIA-supported hosting configuration.
- "Visible in `nvidia-smi`" is not enough to list confidently. We need compute load, burn-in, cold reboot persistence, and container-level GPU checks.
- Even if the unlock works, the machine must still be listed honestly as CMP 170HX. It should not be represented as A100.

Reference repo:

- `cmpunlocker`: <https://github.com/amoghmunikote/cmpunlocker>

---

## 4. Proposed deployment sequence

We should run this in gated phases.

### Phase 0: Access, inventory, and safety checks

Goal: confirm the site is even listable before we spend time on software polish.

Required checks:

- Confirm a real public IP is available. If Bryan is behind CGNAT, Vast inbound renter connectivity will fail.
- Confirm remote admin path: VPN, SSH, and private IPMI.
- Confirm on-site hands exist for power, cables, BIOS, and any physical GPU troubleshooting.
- Inventory each chassis:
  - GPU count
  - 8 GB vs 10 GB CMP 170HX variants
  - SSD layout
  - NIC mapping
  - IPMI address
  - both CPU sockets alive
- Confirm the servers are plugged into the 10G path on the UniFi side, not stranded on 2.5G switching.

Stop conditions:

- No public IP
- No workable remote access
- IPMI exposed on WAN
- Hardware instability before OS work starts

### Phase 1: Thin Ubuntu + Docker + stock NVIDIA bring-up

Goal: stable baseline before any unlock attempt.

Steps:

1. Install Ubuntu LTS on each G481 host.
2. Configure only what is needed for hosting:
   - SSH keys
   - host firewall
   - Docker
   - NVIDIA driver/toolkit
   - logging basics
3. Verify baseline with stock driver:
   - `nvidia-smi`
   - Docker GPU passthrough
   - container sees the GPU
4. Disable unattended package/driver changes on the GPU hosts. Vast explicitly warns against automatic updates that can disrupt active jobs.

Notes:

- We want the box thin before unlock work.
- No local dashboard, no extra reverse proxy, no exposed helper UI.

### Phase 2: CMP unlock on one host only

Goal: prove the unlock is stable before cloning anything.

Recommended approach:

1. Start on one chassis only.
2. Record pre-unlock baseline:
   - stock `nvidia-smi`
   - stock VRAM report
   - Docker GPU visibility
   - thermals at idle
3. Apply `cmpunlocker` exactly against the supported driver path.
4. Cold reboot if required by the repo instructions.
5. Verify:
   - expected post-unlock memory report
   - no broken module load
   - no repeated driver crashes in logs
   - Docker still sees the GPU cleanly
6. Run compute validation:
   - simple CUDA container smoke test
   - stress with `gpu-burn`
   - longer soak under realistic load if time allows
7. Only if stable should we treat the image as a candidate baseline for host B.

Stop conditions:

- unlock does not persist across reboot
- thermals or power become unstable under burn
- repeated NVIDIA/kernel faults
- Docker GPU runtime becomes flaky
- Vast self-test or simple renter-style container testing fails

### Phase 3: UniFi / Ubiquiti hardening

Goal: expose only renter traffic, keep management private.

Design:

- WAN / External zone: default deny inbound
- Rental zone: G481 host rental NICs, only Vast-exposed renter ports
- Mgmt zone: IPMI, host admin SSH, controller/admin access
- VPN zone: remote admin entry point

Rules:

- WAN -> Rental: allow only the intended TCP renter port range by DNAT
- WAN -> Mgmt: deny
- Rental -> Mgmt: deny
- VPN -> Mgmt: allow admin access
- Host firewall: allow renter range plus SSH from management paths only

Specific UniFi guidance from official docs:

- UniFi supports zone-based firewalls for segmenting WAN, internal, VPN, and custom zones.
- WireGuard and Teleport are both supported remote-access options on UniFi gateways.
- The UXG-Fiber provides 10G WAN/LAN capability and is rated for 5 Gbps IDS/IPS throughput.

Meaning for this site:

- We should prefer Teleport or WireGuard over exposing SSH to the public internet.
- The G481 hosts should use the 10G path.
- IPMI must stay off the public internet.

Reference docs:

- UniFi Zone-Based Firewalls: <https://help.ui.com/hc/en-us/articles/115003173168-Zone-Based-Firewalls-in-UniFi>
- UniFi WireGuard VPN Server: <https://help.ui.com/hc/en-us/articles/115005445768-UniFi-Gateway-WireGuard-VPN-Server>
- UniFi Teleport VPN: <https://help.ui.com/hc/en-us/articles/5246403561495-UniFi-Gateway-Teleport-VPN>
- UXG-Fiber specs: <https://techspecs.ui.com/unifi/advanced-hosting/uxg-fiber?subcategory=all-advanced-hosting>

### Phase 4: Vast listing, self-test, and first renter simulation

Goal: confirm the machine is not just "working on the bench" but actually rentable.

Checklist:

1. Create or confirm a separate Vast hosting account.
2. Install Vast host software.
3. Open and verify the public port range.
4. List the machine honestly as CMP 170HX with the actual visible VRAM and real performance characteristics.
5. Run:
   - Vast self-test
   - Vast CLI search to confirm the listing appears
   - self-rental or separate-client test for SSH/Jupyter/direct connectivity
6. Confirm no unrelated workloads are sharing the box while rented.

Important Vast specifics:

- To be listable, Vast expects Ubuntu 18.04+ and an open port range mapped to the machine.
- For verification eligibility, Vast documents at least 3 open ports per GPU, with 100 recommended.
- The self-test checks driver setup, network readiness, open ports, PCIe bandwidth, VRAM capacity/reliability, RAM/CPU, and machine behavior under a test workload.
- Mining-style rigs may never become quickly verified, so "rentable and stable" matters more than chasing a badge.

### Phase 5: Clone to host B only after A is proven

Once host A is stable:

- pin the working baseline
- document driver version and unlock path
- repeat on host B
- do not treat host B as "just the same box" until it passes its own burn and networking checks

---

## 5. Networking model for this site

Recommended physical/logical layout:

```text
Internet / Fiber
    |
UXG-Fiber
    |
    +-- Rental VLAN / zone
    |      +-- G481-A 10GbE
    |      +-- G481-B 10GbE
    |
    +-- Mgmt VLAN / zone
    |      +-- IPMI A
    |      +-- IPMI B
    |      +-- optional host admin NIC / admin path
    |
    +-- VPN / admin entry
```

Design rules:

- No Cloudflare or reverse proxy in front of Vast renter ports.
- No IPMI or host SSH on public WAN forwards.
- No mixing home/office devices into the rental network if avoidable.
- If Bryan wants dashboarding, keep it off-box and outbound-only from the hosts.

---

## 6. What I would actually build

If the assignment is software/operator execution rather than just advisory review, the implementation package should include:

- one repeatable Ubuntu host bootstrap
- one NVIDIA + Docker validation path
- one gated unlock procedure for CMP 170HX
- one burn-in checklist
- one host firewall baseline
- one UniFi review and recommended rule set
- one Vast readiness checklist
- one cloning path from host A to host B
- one short runbook Bryan can use without me online

Optional but reasonable:

- tiny outbound health agent
- webhook/notification path for host down / recovery
- simple status dashboard off the rental hosts

Not in scope by default:

- public product UI on the rental servers
- multi-tenant billing platform beyond Vast
- custom renter isolation instead of Vast's own mechanism
- promise of production support for all future `cmpunlocker` or driver changes

---

## 7. Biggest risks

### A. Unlock risk

The biggest technical unknown is still the CMP unlock path. We can reduce risk with discipline, but not eliminate it:

- unlock may appear successful but fail under load
- reboot persistence may be inconsistent
- driver version pinning may become operationally brittle
- a future kernel update can break the working state

Mitigation:

- pin image and driver versions
- disable automatic updates on rental hosts
- prove cold reboot + burn + container runtime before listing

### B. Networking risk

The most likely "it works locally but not on Vast" failure is bad WAN or bad NAT:

- CGNAT
- wrong forward range
- server on 2.5G instead of 10G path
- IPMI or SSH accidentally exposed

Mitigation:

- verify public IP first
- do real renter-style connectivity tests, not just LAN tests

### C. Operational honesty risk

If the cards are unlocked, Bryan may be tempted to market them like A100-class gear. That is a mistake.

- list exactly what the machine is
- do not overstate VRAM or performance beyond what is proven
- do not promise verification or enterprise-grade consistency until the machine has earned it

---

## 8. Recommended deliverables for Bryan

Practical deliverables:

1. `Host_A_Baseline.md`
   - BIOS/firmware facts
   - NIC mapping
   - driver version
   - Docker/runtime version
   - unlock result

2. `UniFi_Hardening_Changes.md`
   - VLANs
   - zone rules
   - DNAT ranges
   - VPN method

3. `Vast_Go_Live_Checklist.md`
   - host account
   - ports
   - self-test
   - self-rental
   - final listing data

4. `Recovery_Runbook.md`
   - what to do if:
     - host disappears from Vast
     - unlock breaks after reboot
     - burn fails
     - renter ports do not connect
     - IPMI is needed

---

## 9. Immediate next questions for Bryan

These are the questions to lock before implementation:

1. How many CMP 170HX are in each chassis, and are they all the same 8 GB vs 10 GB variant?
2. Do we already have a public IP, or are we behind CGNAT?
3. Does Bryan want me to apply UniFi policy changes directly, or review while he applies them?
4. Is there reliable on-site hands support for reboots, cables, BIOS, and stuck hardware?
5. Is the goal "one stable host listed first" or "both hosts listed immediately"?
6. Does Bryan want only Vast hosting, or also an off-box telemetry/dashboard service?
7. Is the client comfortable with the experimental nature of the CMP unlock, provided we gate it behind burn and self-test before listing?

---

## 10. Recommended stance

The cleanest professional stance is:

- first make one host stably rentable on Vast
- then prove the CMP unlock survives real compute usage
- then harden UniFi and management paths
- then list honestly and test like a renter
- only after that, clone the pattern to host B

That path is slower than "install everything and hope," but it is the one most likely to keep Bryan out of avoidable downtime and reputational damage once renters start showing up.
