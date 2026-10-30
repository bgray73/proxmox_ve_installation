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
      `docs/POWER-NUT.md` (USB from UPS to pbs01).

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
      (Tracked separately as the Isaac firmware/driver update goal.)

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
      ntfy is the live instance. Two guests beyond the original plan:
      VM 303 livepca-01 and VM 304 trex-01; see the fleet table below.)
- [ ] Wire notifications per `docs/NOTIFICATIONS.md`; confirm a test
      alert reaches your phone.
      (ntfy push to iPhone verified 2026-10-28 via the Lenovo
      instance; the Kuma → ntfy notification hookup is unconfirmed.)

## Phase 9 — Backups and monitoring

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

## As-built fleet status (verified live 2026-10-30)

| VMID | Name          | Type | Node  | IP                | Status |
|------|---------------|------|-------|-------------------|--------|
| 200  | adguard       | CT   | pve01 | 10.10.41.10       | running |
| 204  | ntfy          | CT   | pve01 | 10.10.41.14       | running (bare OS — Lenovo ntfy is the live one) |
| 301  | docker-01     | VM   | pve01 | 10.10.41.21       | running |
| 303  | livepca-01    | VM   | pve01 | DHCP (.129)       | running — licensed, capturing the Nexus SPAN feed |
| 201  | proxy (NPM)   | CT   | pve02 | 10.10.41.11       | running |
| 202  | uptime (Kuma) | CT   | pve02 | 10.10.41.12       | running |
| 203  | semaphore     | CT   | pve02 | 10.10.41.13       | running |
| 300  | observability | VM   | pve02 | 10.10.41.20       | running |
| 302  | pdm01         | VM   | pve02 | 10.10.41.22       | running (HA) |
| 304  | trex-01       | VM   | pve02 | 10.10.41.23       | running (rebuilt 2026-10-30; traffic gen via kernel tools — DPDK passthrough parked) |
| 305  | scanopy-01    | VM   | pve02 | 10.10.41.25       | running (Scanopy stack up; first discovery not yet run) |

Still to deploy: **pve03** (node install, needs a second SSD) and
**pbs01 / PBS** (Phase 6 — 9300-8i HBA swap first), then the PDM→pbs01
remote and the Phase 9 backup jobs that depend on PBS.
