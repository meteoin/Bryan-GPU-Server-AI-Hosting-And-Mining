# Bryan x Eqan Ahmad

Linux / Docker / Python | Two G481-HA0 hosts on Vast.ai

**Positioning:** Burn, harden, pin and list. Stats live off the GPU hosts.

---

## Three Phases

```mermaid
flowchart LR
    A[0 Access] --> B[1 Stress]
    B --> C[2 Harden]
    C --> D[3 GitHub + Vast + stats]
    D --> E[List + clone B]
    %% Animated flow: burn then harden then list
    A e1@--> B
    B e2@--> C
    C e3@--> D
    D e4@--> E
    e1@{ animation: fast }
    e2@{ animation: slow }
    e3@{ animation: fast }
    e4@{ animation: slow }
```

| Phase | Done when | Stop if |
|---|---|---|
| 0 | VPN, IPMI, public IP, GPU count | CGNAT or no access |
| 1 | **gpu-burn** stable | unlock, heat, PSU |
| 2 | IPMI dark, DNAT range | mgmt on WAN |
| 3 | listed, B cloned, stats in DB | would change drivers live |

---

## Site

```mermaid
flowchart LR
    A[Fiber] --> B[UXG-Fiber]
    B --> C[Rental VLAN]
    B --> D[Mgmt VLAN]
    C --> E[G481 A / B]
    E --> F[Vast daemon]
    F --> G[Renters]
    D --> H[IPMI]
    D --> I[VPN]
    E -.-> J[Koyeb API + Postgres]
    %% Animated flow: renters on Vast, stats off-box
    A e1@--> B
    B e2@--> C
    C e3@--> E
    E e4@--> F
    F e5@--> G
    E e6@-.-> J
    e1@{ animation: fast }
    e2@{ animation: fast }
    e3@{ animation: fast }
    e4@{ animation: fast }
    e5@{ animation: slow }
    e6@{ animation: slow }
```

Renters: UniFi DNAT. Admin SSH: VPN. Stats: HTTPS push to Koyeb, not on the G481s.

---

## Phase 0: Access

| Need | Why |
|---|---|
| VPN + SSH + IPMI | remote |
| On-site hands | GPU, PSU, POST |
| Public IP, not CGNAT | Vast inbound |
| GPU count, 8 vs 10 GB | same-model listing |
| Both sockets live | dual-root |
| Vast hosting account | not a renter account |

---

## Phase 1: Stress

```mermaid
flowchart LR
    A[Ubuntu + driver + Docker] --> B[170HX persist]
    B --> C[nvidia-smi]
    C --> D[gpu-burn]
    D --> E[Phase 2]
    D --> F[Stop]
    %% Animated flow: thin stack then burn gate
    A e1@--> B
    B e2@--> C
    C e3@--> D
    D e4@--> E
    e1@{ animation: fast }
    e2@{ animation: fast }
    e3@{ animation: slow }
    e4@{ animation: slow }
```

Thin stack only. `oguzpastirmaci/gpu-burn --gpus all`. Watch heat. List as CMP 170HX, not A100.

---

## Phase 2: Harden (I own)

```mermaid
flowchart TD
    A[UniFi] --> B[Rental vs Mgmt]
    B --> C[IPMI off WAN]
    B --> D[DNAT range]
    C --> E[VPN then SSH]
    D --> F[Host ufw]
    %% Animated flow: zones then IPMI then ports
    A e1@--> B
    B e2@--> C
    B e3@--> D
    C e4@--> E
    e1@{ animation: fast }
    e2@{ animation: fast }
    e3@{ animation: fast }
    e4@{ animation: slow }
```

| I configure | Not this job |
|---|---|
| Zones, UPnP off, IDS/IPS | Pen test |
| IPMI private, SSH keys | Cloudflare on renter ports |
| DNAT range, host ufw | Renter isolation (Vast) |
| 10G uplinks | On-site cabling |

---

## Phase 3: GitHub + Vast

```mermaid
flowchart LR
    A[Pinned GitHub tag] --> B[Host agent]
    B --> C[Baseline]
    C --> D[Vast list]
    D --> E[Clone B]
    B --> F[Push stats]
    F --> G[Koyeb API + DB]
    %% Animated flow: pin apply list clone, stats off-box
    A e1@--> B
    B e2@--> C
    C e3@--> D
    D e4@--> E
    B e5@--> F
    F e6@--> G
    e1@{ animation: fast }
    e2@{ animation: fast }
    e3@{ animation: slow }
    e4@{ animation: slow }
    e5@{ animation: fast }
    e6@{ animation: slow }
```

| Do | Do not |
|---|---|
| Read-only deploy key | Write token on the GPU host |
| Pin tag, unlist then apply | Follow `main` or live driver update |
| Tiny metrics agent on G481 | Postgres / API on G481 |

---

## Stats DB + Admin Dashboard

```mermaid
flowchart LR
    A[G481 A agent] --> C[Koyeb API]
    B[G481 B agent] --> C
    C --> D[Koyeb Postgres]
    D --> E[Admin dashboard]
    %% Animated flow: agents push HTTPS to Koyeb, rentals stay local
    A e1@--> C
    B e2@--> C
    C e3@--> D
    D e4@--> E
    e1@{ animation: fast }
    e2@{ animation: fast }
    e3@{ animation: fast }
    e4@{ animation: slow }
```

| Store | Do not store |
|---|---|
| Temp, power, GPU util, VRAM | Renter containers / models |
| Disk, RAM, daemon up/down | Vast customer data |
| Burn history, downtime | DB or API on a G481 |

Agents: outbound HTTPS + token. Dashboard: login. Two hosts will not need much scale; Koyeb is so we do not babysit a stats VM. Keep Postgres warm enough that ingest does not sleep.

---

## Close

Burn. Harden. Pin, list, push stats to Koyeb. No listing without load. No database on the rental GPUs.

