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

- [ ] Configure the Nexus from `network/nexus9k.example.cfg`
      (MTU 9216, native VLAN 998, BPDU guard) against the corrected
      `network/PORT-MAP.md`.
- [ ] Configure the UCG-Fiber (VLANs, firewall policy, gateways) and
      work the UCG verification checklist to done.
- [ ] Verify jumbo frames end-to-end and confirm VLAN 21 stays pure
      L2 (no gateway, no Tailscale route). See `docs/TOPOLOGY.md`.

## Phase 3 — Install media

- [ ] Build the Ventoy stick per `docs/INSTALL-MEDIA.md`; verify ISO
      hashes against the signed `SHA256SUMS`.

## Phase 4 — Proxmox VE install and burn-in

- [ ] Install PVE 9 on pve01–pve03 (VLAN 20 management, MTU 9000 on
      data interfaces).
- [ ] Run burn-in per `docs/BURN-IN.md` before trusting any node.
- [ ] Apply firmware updates per `docs/FIRMWARE.md`.

## Phase 5 — Cluster

- [ ] Form the 3-node cluster; Corosync on VLAN 21 (pure L2).
- [ ] Verify quorum, fencing/HA behavior; active-backup bond on the
      40Gb/10Gb pairs.

## Phase 6 — Proxmox Backup Server

- [ ] Install the 9300-8i in pbs01; confirm direct disk/SMART
      visibility through the IT-mode HBA.
- [ ] Install PBS 4.2; create pools per `docs/PBS-STORAGE.md`
      (re-verify disk health before `zpool create`).
- [ ] Create datastores; configure `docs/PBS-MAINTENANCE.md`
      (verify jobs, GC, prune).

## Phase 7 — Datacenter Manager

- [ ] Deploy `pdm01` per `docs/PDM.md`; add the PVE cluster and pbs01
      as remotes with least-privilege API tokens.

## Phase 8 — Infrastructure services

- [ ] `automation/terraform/README.md`: AdGuard, proxy, uptime,
      semaphore, ntfy, observability, docker (VLAN 41).
- [ ] Wire notifications per `docs/NOTIFICATIONS.md`; confirm a test
      alert reaches your phone.

## Phase 9 — Backups and monitoring

- [ ] `docs/BACKUP-JOBS.md`: backup jobs to PBS (covers all guests).
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
- [ ] Record results; open issues for anything that surprised you.
