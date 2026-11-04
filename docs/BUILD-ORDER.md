# Build order

The single ordered checklist from empty rack to finished homelab. Each
phase gates the next — do not skip ahead past a verification step.

## Phase 0 — Plan and inventory

- [ ] Complete `inventory.json`: Dell service tags, Supermicro serial,
      every disk model/serial/capacity/slot, NICs, PSUs.
- [ ] Confirm parts on hand: LSI 9300-8i (IT mode), low-profile
      bracket, SFF-8643 cabling, 2.5"-to-3.5" SSD adapters, spare
      512 GB SSD.
- [ ] Physically verify the HBA, bracket fit, and backplane cabling
      before pool creation (see `docs/PBS-STORAGE.md`).

## Phase 1 — Rack and power

- [ ] Rack all four nodes per `docs/RACK-LAYOUT.md`; cable power.
- [ ] Verify UPS/PDU capacity; wire the NUT topology in
      `docs/POWER-NUT.md`.
      (As-built change 2026-11-01: the Pi-hole Pi died in October
      2026, so the NUT master role moved to the Lenovo G550 — configs
      staged there, services still dark pending the plug/test day.
      A third UPS, a CyberPower CP1500PFCRM2U, feeds the network
      chain: wall → UPS → UniFi PDU Pro → network gear. See the
      as-built note in `docs/POWER-NUT.md`.)

## Phase 2 — Network

- [x] Configure the Nexus from `network/nexus9k.example.cfg`
      (MTU 9216, native VLAN 998, BPDU guard) against the corrected
      `network/PORT-MAP.md`. (Done 2026-10; as-built ports in PORT-MAP.)
- [x] Configure the UCG-Fiber (VLANs, firewall policy, gateways) and
      work the UCG verification checklist to done. (Done 2026-10-30;
      scoped Allow policies added as the fleet came up.)
- [ ] Verify jumbo frames end-to-end and confirm VLAN 21 stays pure
      L2 (no gateway, no Tailscale route). See `docs/TOPOLOGY.md`.
      (Deferred: Corosync runs on VLAN 20 as-built; a dedicated
      VLAN 21 ring is a later change.)

## Phase 3 — Install media

- [x] Build the Ventoy stick per `docs/INSTALL-MEDIA.md`; verify ISO
      hashes against the signed `SHA256SUMS`.
      (Done differently 2026-10-28/30: SHA256-verified ISOs are served
      from the Lenovo NFS repo — PVE storage `lenovo-images` — and
      automated-install ISOs were built with the answer-file kit.)

## Phase 4 — Proxmox VE install and burn-in

- [x] Install PVE 9 on pve01–pve03 (VLAN 20 management, MTU 9000 on
      data interfaces).
      (pve01 + pve02 done 2026-10-29, PVE 9.2 / ZFS RAID1. pve03 still
      to install — waiting on a second SSD.)
- [ ] Run burn-in per `docs/BURN-IN.md` before trusting any node.
- [ ] Apply firmware updates per `docs/FIRMWARE.md`.
      (Tracked separately as the Isaac firmware/driver update goal.
      Check-only pass done 2026-10-31; the first update attempt
      failed at Lifecycle Controller staging — RED085 — with nothing
      applied. Completed 2026-11-03, iDRAC-first via the WebUI: both
      R640 nodes now run iDRAC 7.00.00.185, BIOS 2.29.2, and NIC
      25.0; see the as-built status in `docs/FIRMWARE.md`.)

## Phase 5 — Cluster

- [x] Form the 3-node cluster; Corosync on VLAN 21 (pure L2).
      (As-built 2026-10-30: 2-node cluster `homelab` (pve01+pve02) plus
      a QDevice on the Lenovo for quorum; Corosync on VLAN 20. pve03
      joins when installed; dedicated VLAN 21 ring deferred.)
- [ ] Verify quorum, fencing/HA behavior; active-backup bond on the
      40Gb/10Gb pairs.
      (Quorum proven live 2026-10-30 when pve02 lost power: cluster
      stayed quorate on pve01+QDevice. HA recovery of pdm01 exposed a
      structural limit — local-zfs disks cannot fail over; storage
      replication (pvesr) is the open fix. No bonds as-built: single
      10G uplink per node; the 40G ports have no transceivers yet.)

## Phase 6 — Proxmox Backup Server

- [ ] Install the 9300-8i in pbs01 (runbook: `docs/HBA-SWAP.md`;
      identify the backplane first); confirm direct disk/SMART
      visibility through the IT-mode HBA.
- [ ] Install PBS 4.2; create pools per `docs/PBS-STORAGE.md`
      (re-verify disk health before `zpool create`).
- [ ] Create datastores; configure `docs/PBS-MAINTENANCE.md`
      (verify jobs, GC, prune).

## Phase 7 — Datacenter Manager

- [x] Deploy `pdm01` per `docs/PDM.md`; add the PVE cluster and pbs01
      as remotes with least-privilege API tokens.
      (pdm01 deployed 2026-10-30, PDM 1.1.9, HA on, homed on pve02;
      PVE cluster remote added. pbs01 remote waits on Phase 6.)

## Phase 8 — Infrastructure services

- [x] `automation/terraform/README.md`: AdGuard, proxy, uptime,
      semaphore, ntfy, observability, docker (VLAN 41).
      (All deployed and running 2026-10-30 — built directly, not via
      terraform apply; as-built node placements are in the terraform
      README table. CT 204 ntfy is a bare OS by choice — the Lenovo
      ntfy is the live instance. Seven guests beyond the original plan
      followed: VM 303 livepca-01, VM 304 trex-01, VM 305 scanopy-01,
      VM 306 vault-01, VM 307 livenx-01, VM 308 homeassistant-01, and
      VM 309 authentik-01; see the fleet table below.)
- [ ] Wire notifications per `docs/NOTIFICATIONS.md`; confirm a test
      alert reaches your phone.
      (As-built: the live alerting path is Uptime Kuma → the Lenovo
      ntfy, topic `homelab-alerts`; ntfy push to iPhone verified
      2026-10-28. The Kuma → ntfy hookup was subtly broken — the
      notification's server URL had the topic appended, so alerts
      arrived as raw JSON text — and was fixed and verified
      2026-11-01; see `docs/NOTIFICATIONS.md`. The PVE-native webhook
      wiring in that doc is not yet the live path.)

## Phase 9 — Backups and monitoring

- [x] Interim (pre-PBS) config-level backups running weekly:
      fleet config bundle (Sun 03:15 → pve02) and Lenovo critical
      backup (Sun 04:15). UniFi is **not** covered — manual export
      from the UniFi UI still owed. See `docs/BACKUP-JOBS.md`.
- [ ] `docs/BACKUP-JOBS.md`: `nightly-prod` → `vm-ssd` and
      `nightly-scratch` → `scratch` jobs; every guest assigned to the
      `prod` or `scratch` pool.
- [ ] `docs/PBS-MAINTENANCE.md`: per-datastore prune/verify/GC jobs;
      retention owned by PBS prune jobs (PVE jobs at `keep-all`).
- [ ] Backup encryption keys exported to two independent locations +
      PBS master key recorded (`docs/PBS-MAINTENANCE.md` procedure).
- [ ] `docs/OFFSITE-PBS.md`: second copy deployed (recommended: offsite
      PBS pull sync, seeded locally first).
- [ ] `docs/BACKUP-RESTORE-TESTS.md`: first restore test, then
      schedule quarterly.
- [ ] `docs/DISK-HEALTH.md`: scrubs, SMART, zed alerts.
- [ ] `docs/DEADMAN-SWITCH.md`: Healthchecks.io live; run the
      cron-pause alert drill.

## Phase 10 — Harden and update

- [ ] `docs/SECURITY.md` hardening pass.
- [ ] `docs/UPDATES.md`: patching runbook; confirm no-subscription vs
      enterprise repos are consistent on every node.

## Phase 11 — Validate

- [ ] Full restore drill of one real VM from PBS.
- [ ] Pull one node (power off) — confirm HA and quorum behave.
      (Happened unplanned 2026-10-30: pve02 lost AC mid-cabling.
      Quorum held; pdm01 HA recovery failed on local-only storage and
      was repaired by hand — see the Phase 5 note. A deliberate
      re-test after replication is configured is still owed.)
- [ ] Record results; open issues for anything that surprised you.

## As-built fleet status (verified live 2026-11-04)

Cluster `homelab`: pve01 (10.10.20.11, 64 GB, UEFI) + pve02
(10.10.20.12, 128 GB, Legacy), PVE 9.2 / ZFS RAID1, QDevice on the
Lenovo (192.168.1.190). Placement settled with no failback after the
2026-11-03 firmware windows — pve02 carries most guests.

| VMID | Name          | Type | Node  | IP                | Status |
|------|---------------|------|-------|-------------------|--------|
| 200  | adguard       | CT   | pve02 | 10.10.41.10       | running (HA) |
| 201  | proxy (NPM)   | CT   | pve02 | 10.10.41.11       | running (HA; 17 proxy hosts behind the Homelab CA) |
| 202  | uptime (Kuma) | CT   | pve02 | 10.10.41.12       | running (Kuma 2.5.9, 2048 MB, 24 monitors + 4 groups; alerts → Lenovo ntfy) |
| 203  | semaphore     | CT   | pve02 | 10.10.41.13       | running (Semaphore 2.19.17) |
| 204  | ntfy          | CT   | pve01 | 10.10.41.14       | running (bare OS — Lenovo ntfy is the live one) |
| 205  | tacacs-01     | CT   | pve02 | 10.10.41.15       | running (tac_plus; both switches + LiveNX authenticate against it) |
| 206  | paperless-01  | CT   | pve02 | 10.10.41.16       | running (Paperless-ngx on PostgreSQL 18.6 + Redis 8; archive still empty) |
| 207  | scrutiny-01   | CT   | pve02 | 10.10.41.17       | running (Scrutiny hub 0.10.0; collectors on both PVE hosts) |
| 300  | observability | VM   | pve02 | 10.10.41.20       | running (Grafana/Prometheus/Loki; PVE exporter covers both nodes) |
| 301  | docker-01     | VM   | pve01 | 10.10.41.21       | running (Homepage :3000, What's Up Docker :3001, SentinelLab :4100, Scrypted :10443 — Ring plugin not configured) |
| 302  | pdm01         | VM   | pve02 | 10.10.41.22       | running (PDM 1.1, HA; homed on pve02 — HA does not fail back) |
| 303  | livepca-01    | VM   | pve01 | 10.10.41.24       | running — licensed (LiveWire 26.2.2); capture feed dark — Nexus monitor session admin-shut since 2026-11-02 |
| 304  | trex-01       | VM   | pve02 | 10.10.41.23       | parked (onboot=0 by design; rebuilt vanilla 2026-10-30 — DPDK passthrough parked after host DMAR faults, traffic generation paused) |
| 305  | scanopy-01    | VM   | pve02 | 10.10.41.25       | running (Scanopy 0.19.5 — see `docs/SCANOPY.md`) |
| 306  | vault-01      | VM   | pve02 | 10.10.41.26       | running (Vaultwarden; HA + 15-min replication) |
| 307  | livenx-01     | VM   | pve01 | 10.10.41.27       | running (LiveNX server 26.2.2, licensed) |
| 308  | homeassistant-01 | VM | pve02 | DHCP (.120)       | running (Home Assistant OS 18.4; Core serves on port 80) |
| 309  | authentik-01  | VM   | pve02 | 10.10.41.28       | running (Authentik 2026.8.5 on PostgreSQL 18.6, HA; SSO live — see below) |

Power-recovery boot order for the original 15 guests was applied
and verified 2026-10-31 — VM 309's missing `onboot` flag was found
and fixed in the process; VM 304 is deliberately manual-start.
CT 201 fronts 17 NPM proxy hosts behind the local Homelab CA (the
serving cert, v8, carries 20 service names as explicit SANs — a bare
wildcard was rejected), and AdGuard holds the matching 20 DNS
rewrites; `.homelab` names resolve only for AdGuard-DNS clients
(house DHCP still hands out public resolvers).

Authentik (VM 309) is the fleet's SSO front door, and the wiring is
done: native OIDC for PVE, PDM, Grafana, What's Up Docker, and
Paperless; NPM forward-auth gating for Uptime Kuma, Scanopy,
SentinelLab, Scrypted, the NPM admin, Homepage, and Scrutiny; SAML
for LiveNX and LivePCA. Native auth stays for Home Assistant,
Vaultwarden, and UniFi. `akadmin` is the break-glass identity,
`bgray` the everyday admin; see `docs/SECURITY.md` for the as-built
detail.

Still to deploy: **pve03** (node install, needs a second SSD) and
**pbs01 / PBS** (Phase 6 — 9300-8i HBA swap first), then the PDM→pbs01
remote and the Phase 9 backup jobs that depend on PBS.
