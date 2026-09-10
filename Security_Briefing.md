# Security briefing: Bryan Vast.ai host site

Read this before the UniFi / network conversation. It is a review checklist, not a claim that you have already hardened this gateway in production.

Your job on security is: **segment the site, expose only Vast renter ports, keep management off the internet.** Vast isolates renters inside Docker. You harden the edge and the host OS.

---

## 1. Threat model (this site only)

Untrusted people will get containers on Bryan's GPUs. Those containers have outbound internet and inbound ports that Vast maps through the router.

| Who | Trust | What they can reach if we misconfigure |
|---|---|---|
| Vast renters | none | GPU container only. Never host SSH, never IPMI, never UniFi |
| Internet scanners | none | Anything we DNAT or leave on WAN |
| You (remote) | admin | SSH / VPN / UniFi only |
| Bryan on-site | owner | same, plus physical console |

The expensive mistakes are not "no IDS." They are:

1. IPMI / BMC on the public internet
2. Host SSH on port 22 forwarded to the world
3. Rental VLAN can talk to management VLAN
4. UPnP or "allow all" WAN rules
5. Extra backends on the GPU host while it is rented
6. Cloudflare / reverse proxy in front of Vast renter ports (breaks rentals and is the wrong trust boundary)

---

## 2. Mental model: zones

Think in **zones**, not in "open this port." UniFi Gateway Fiber (UXG-Fiber) is a zone-based firewall with stateful + Layer 7 rules and IDS/IPS (about **5 Gbps** with IPS on).

```
Internet
    |
  WAN zone          <- default deny inbound
    |
  UXG-Fiber
    |-- Rental zone     G481 10GbE NICs, Vast DNAT range only
    |-- Mgmt zone       IPMI AST2500, UniFi, host SSH
    |-- Admin/VPN zone  you, after WireGuard / Teleport / similar
```

Default between zones: **deny**. Then allow only:

- WAN → Rental: the Vast TCP port **range** (DNAT), not "any"
- Admin/VPN → Mgmt: SSH, IPMI web, UniFi
- Rental → Mgmt: **nothing**
- Mgmt → WAN: updates when you choose a window (not unattended on GPU hosts)

UXG-Fiber also has 4x **2.5GbE** and **10G** SFP+/RJ45. Put the G481 **10GbE** uplinks on the 10G path. Do not hang rental servers off 2.5G switch ports.

---

## 3. UniFi review (what to look at with Bryan)

Ask for screenshots or a screen-share. You are reading policy, not guessing.

**WAN**

- Public IP vs CGNAT. Vast inbound ports need a real public IP (or 1:1 NAT). CGNAT = renters cannot connect.
- WAN type: SFP+ fiber vs RJ45. Failover if any.
- UPnP: **off**. Vast ports are explicit DNAT, not device self-open.
- IDS/IPS: **on** for a site like this. Note the 5 Gbps IPS cap; Vast verify only needs ~500 Mbps, so IPS is not the bottleneck.

**NAT / port forwards**

- One **TCP range per chassis** (example shape: 10000-11000 host A, 11000-12000 host B). Exact numbers TBD after GPU count.
- Forward to the host's rental NIC IP, not to IPMI.
- Protocol TCP first. Do not forward "all ports 1-65535."
- No forward of 22, 80, 443, 623, 5900, or IPMI ports from WAN unless Vast itself mapped them as renter ports (those land on the **container**, not on host sshd).

**Networks / VLANs**

- Separate corporate/home Wi-Fi from rental servers.
- IPMI on its own VLAN or at least Mgmt, never on Rental.
- Guest / IoT cannot reach G481 or IPMI.
- Inter-VLAN routing: deny Rental → Mgmt.

**Admin access**

- UniFi itself is not a WAN app. Adopt via Cloud Key / UniFi Network / official hosting, not "expose controller to 0.0.0.0."
- Your remote access: VPN into Admin zone, then SSH. Not a public jump host if we can avoid it.
- Teleport / WireGuard on the UXG are built-in options. Prefer that over opening SSH to the world.

**What "review" sounds like when you talk**

> I want to see WAN IP type, current port forwards, VLAN list, whether IPMI has a public NAT, and whether UPnP is on. Then we put renters on a dedicated VLAN, IPMI on mgmt, and a tight DNAT range per host.

You do not need to claim you designed UniFi firmware. You need to know what good looks like and what to change.

---

## 4. IPMI (AST2500 on G481-HA0)

Each chassis has a dedicated management NIC (Aspeed AST2500). It is a small computer beside the server OS. If it is on the internet, people will find it.

**Good**

- Cable IPMI to Mgmt VLAN only
- Change default password
- No WAN DNAT to IPMI
- You reach it only over VPN
- Firmware not ancient (Bryan/on-site can check)

**Bad**

- IPMI on the same LAN as Vast renter NICs
- Default `admin/admin` still there
- Port 623 or 80/443 forwarded from WAN

IPMI is how you recover a hung Ubuntu box remotely. Keep it, just keep it private.

---

## 5. Ubuntu host hardening (your actual work)

Vast wants the machine **dedicated while rented**. Security and that rule agree: little else should listen on the host.

| Control | Default for this job |
|---|---|
| SSH | keys only, no password, not on WAN 22 |
| `ufw` or nftables | allow UniFi DNAT range + SSH from Mgmt; deny the rest |
| Docker socket | root-only, never published to a renter network |
| Unattended upgrades | **off** on GPU hosts (Vast: a driver update kills a rental). Patch in a listed-off window |
| Extra web UIs | off (no Portainer on :9000 to the world) |
| Users | one admin account, sudo, no shared root password in chat |
| Secrets | Vast API key and SSH keys not in git |

Smoke test that is also a security test: from the internet, only the Vast range answers. Host SSH and IPMI do not.

Renter isolation (namespaces, cgroups, GPU assign) is **Vast daemon + Docker**. Do not add a second reverse proxy in front of that.

---

## 6. Vast-specific security facts

- **Separate accounts:** hosting account ≠ renter account.
- **Listing honesty:** CMP 170HX, real VRAM, not "A100." That is policy as well as ops.
- **Ports:** renters get mapped ports on the public IP. That is required. The host must not also expose management on those same rules by accident.
- **No side workloads** while rented: your health script is fine; a full extra backend is not.
- **CMP unlock:** community kernel/driver patching is experimental. Treat it as extra risk (stability + unsigned modules). Unlock for CUDA bring-up; do not treat it as a security feature.

---

## 7. Cloudflare / reverse proxy

| Use | Do not use |
|---|---|
| Optional later: tunnel for a **tiny admin agent** | In front of Vast renter ports |
| UniFi Teleport / WireGuard for you | "One Cloudflare hostname = the GPU server" |

Renters must hit the real public IP:port that Vast advertised. A proxy in the middle breaks that contract.

---

## 8. First conversation checklist

Copy this into the call:

- [ ] Public IP or CGNAT?
- [ ] UPnP on or off?
- [ ] List of current port forwards
- [ ] Is IPMI reachable from a phone on LTE (should be **no**)?
- [ ] How many VLANs exist today?
- [ ] Where do the G481 10GbE cables land (10G vs 2.5G)?
- [ ] Who else is on the LAN (home PCs, cameras)?
- [ ] How will I VPN in on day one?

If IPMI answers from LTE, that is the first fix, before listing on Vast.

---

## 9. How to stay honest

You have strong Linux / Docker / GPU host experience. You do **not** have a UniFi production hardening track record. Say:

> I will review this like a host operator: zones, WAN exposure, IPMI, SSH, and the Vast port range. I will use UniFi's zone firewall and VPN rather than inventing a custom edge. If something needs a UniFi specialist beyond gateway policy, I will flag it.

That is enough to do the review Bryan asked for. It is not a pen test and you should not offer one.

---

## 10. Short study (30-45 min)

1. UniFi zone-based firewall: WAN / LAN / VPN / VLAN, default deny, allow-list.  
2. DNAT vs WAN firewall allow: a forward still needs a WAN rule.  
3. Vast host networking: open a **range** per machine, not random single ports.  
4. Why BMC/IPMI on WAN is a standing incident.

Do not study exploits. Study the default-deny picture above until you can draw it from memory.
