# Disaster recovery — full-site rebuild

**Scope: everything is dead** — all PVE nodes and PBS are gone or untrusted.
If only one node or only PBS failed, stop: you need the partial-failure path,
not this document.

Read this whole page once before touching anything. Each phase gates the next;
do not skip ahead.

## Phase 0 — Triage (5 minutes, no keyboard yet)

1. **Decide the PBS datastore situation.** This is the single most important
   decision in this document.
   - Data disks physically intact → you will **reattach**, never reformat.
   - Data disks dead/lost → you are restoring from your off-site/second copy.
     If you have no second copy, say so now and adjust expectations: guests
     get rebuilt from scratch, not restored.
2. Gather the offline essentials (Phase 7). If any are missing, stop and
   recover them first — rebuilding without the answer token or PBS fingerprint
   wastes hours.

## Phase 1 — Power and network

Nothing else is reachable without this. Power-on order:

1. Wall power → UPS (verify it is on utility/battery-normal, not faulted).
2. Switches: Catalyst 2960-X, then Nexus 9K. Wait for full boot.
3. UCG Fiber gateway. Wait for UniFi OS.
4. PBS host (iDRAC/IPMI virtual console if needed).
5. PVE nodes — leave them **off** until Phase 4.

Then re-apply network config:

6. Compare each switch's running config against this repo and re-apply what is
   missing: `network/catalyst2960x-oob.example.cfg`,
   `network/nexus9k.example.cfg`. **Review interface numbers before pasting —
   they are placeholders.**
7. Gateway: follow `network/UCG_Fiber_Gateway` — Networks, port profiles on the
   two trunk ports, firewall rules, mDNS on VLANs 60/70.
8. Verify: from a laptop on the management network, ping `10.10.10.1`,
   `10.10.20.1`, each iDRAC (`10.10.10.11–13`), and the Supermicro BMC.
   If iDRACs are unreachable, nothing below works — fix Layer 2 first.

## Phase 2 — Firmware (conditional)

**Skip this phase unless hardware was replaced.** Firmware does not evaporate;
re-flashing healthy boards buys nothing.

If a system board, NIC, or storage controller was swapped:

1. Follow `docs/FIRMWARE.md` and run `scripts/update_firmware.sh`
   (`dell --via idrac` for the Dells, `supermicro` on pbs01).
2. Re-record the new board's serial/service tag — the automated installer
   matches hosts by Dell service tag first.

## Phase 3 — PBS

1. **Rebuild the automated PBS ISO if you need to.** The ISOs live in `output/`
   (gitignored) and embed `ANSWER_TOKEN` from `.env` (also gitignored).
   - Have your `.env` copy → `make isos` per README.
   - Lost it → `make rotate-token`, rebuild ISOs, restart the answer server.
     Old tokens die with the old cluster; this is safe.
2. Boot pbs01 from `output/proxmox-backup-server-auto.iso` via IPMI virtual
   media. Verify the answer server identifies `pbs01` and
   `/root/proxmox-deployment/first-boot-complete` exists after install.
3. **Install to the OS mirror ONLY. Do not touch the data disks.**
   - Datastore was ZFS → `zpool import` the existing pool. Never `zpool create`
     over it.
   - Datastore was ext4/XFS on hardware RAID → verify the array is intact in
     the controller BIOS, then mount by UUID.
4. Confirm the mount is persistent (`findmnt`, fstab / systemd `.mount` /
   ZFS dataset), then re-create the datastore registration:

   ```bash
   post-deploy/create_pbs_datastore.sh --dry-run pbs-main /backup/pbs-main
   post-deploy/create_pbs_datastore.sh pbs-main /backup/pbs-main
   ```

   The script refuses transient mounts. Override with `ALLOW_TRANSIENT_MOUNT=1`
   only if you understand why it refused.
5. Verify: PBS web UI shows the datastore with expected usage and snapshot
   counts. If the datastore is empty and you expected data, **stop** — you are
   about to build on nothing. Re-examine step 3.

## Phase 4 — PVE nodes

1. Rebuild `output/proxmox-ve-auto.iso` if needed (same token logic as Phase 3).
2. In each iDRAC, mount the ISO as virtual media, one-time boot from virtual
   CD/DVD. **Boot pve01 first**, watch the answer-server log for the correct
   host match, verify FQDN/IP and `first-boot-complete` — then boot pve02 and
   pve03 in parallel. Unmount virtual media when done.
3. Re-form the cluster (old cluster state died with the nodes; there is
   nothing to "rejoin"):

   ```bash
   # on pve01
   post-deploy/create_cluster.sh --dry-run homelab
   post-deploy/create_cluster.sh homelab
   # on pve02, then pve03, one at a time
   post-deploy/join_cluster.sh --dry-run <pve01-management-IP>
   post-deploy/join_cluster.sh <pve01-management-IP>
   ```

4. Verify: `pvecm status` shows 3 nodes, quorate (needs 2 of 3 votes).

## Phase 5 — Restore guests

1. Re-register PBS in PVE: Datacenter → Storage → Add → Proxmox Backup
   Server. You need the PBS address, datastore name, API token, and
   **fingerprint** — all in Phase 7.
2. **Decision: Terraform state.** If your terraform state file survived
   (it lived wherever you ran `apply`), you may use it. If it is gone,
   **do not run `terraform apply`** — with no state it will try to create
   guests that already exist once restored. Restore from backup first; deal
   with state via `terraform import` later, or not at all.
3. Restore in dependency order: **AdGuard (DNS) first**, then the reverse
   proxy, then monitoring/automation, then everything else. A guest that
   boots before DNS exists will just retry; still, DNS first saves confusion.
4. Mechanics: `docs/BACKUP-RESTORE-TESTS.md` (restore from newest backup,
   same as the quarterly test but keeping the network attached).
5. Re-apply post-deploy Ansible hardening if it was applied before
   (`automation/ansible/`), and re-create anything that lived only in cluster
   config: **backup jobs/schedules, replication jobs, HA groups/resources,
   firewall rules, SDN VNets.** These died with the cluster — they are not in
   the guest backups.

## Phase 6 — Verify

Run in order; do not declare victory early.

1. `pvecm status` — 3 nodes, quorate.
2. Every guest `running`; spot-check services: DNS resolves, proxy serves
   HTTPS, PBS web UI loads.
3. `zpool status` / SMART on all nodes — no degraded pools, no failing disks.
4. Backup jobs re-created → run one manually → green. Then confirm the
   schedule is enabled.
5. `scripts/pbs_restore_test.sh --mode test --vmid <canary>` — the same
   smoke test as quarterly; it must PASS on the fresh system.
6. Remote access: Tailscale subnet router online, routes
   (`10.10.10.0/24, 10.10.20.0/24, 10.10.30.0/24, 10.10.41.0/24`) approved in
   the admin console, and you can reach an iDRAC and the PVE UI remotely.
7. Rotate the answer token (`make rotate-token`, rebuild ISOs) if the old
   token was ever exposed during recovery.

## Phase 7 — Offline essentials

Everything below must exist **outside** the cluster. If it only exists inside
the cluster, it does not exist. Review this list quarterly.

- [ ] Password manager: iDRAC/BMC credentials, PBS admin, PVE root, UPS/PDU,
      switch enable secrets, UniFi account, Tailscale admin.
- [ ] PBS API token + secret and the **PBS fingerprint** (needed to re-add
      the storage in Phase 5).
- [ ] Copy of `.env` (the `ANSWER_TOKEN`) — gitignored, not on GitHub.
- [ ] This repo — GitHub counts, plus a local clone somewhere off-cluster.
- [ ] Built ISOs in `output/` — or the ability to rebuild them (`make isos`).
- [ ] Switch running-config backups (`show running-config` from both
      switches, dated).
- [ ] `inventory.json` with real service tags, MACs, and serials (gitignored).
- [ ] `/root/idracs.txt` contents (iDRAC name → IP mapping).
- [ ] Terraform state file, if you intend to `apply` again without imports.
- [ ] This document, printed or on a device that does not depend on the
      homelab to read.
