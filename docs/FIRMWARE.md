# Firmware maintenance

Update firmware **before** Proxmox is installed, then keep it current on a
cadence. Stale iDRAC/BMC, BIOS, NIC, and storage-controller firmware is a
common source of install failures, phantom hardware faults, and
unexplained reboots.

The scripted path is `scripts/update_firmware.sh`:

- **Dell** nodes use Dell System Update (DSU). DSU can push firmware through
  iDRAC over the network with no OS installed, and it also runs locally on a
  Proxmox node (Proxmox VE is Debian-based, which Dell documents DSU as
  working with).
- **Supermicro** uses Supermicro Update Manager (SUM) in-band on the host.
  In-band SUM is free; OOB (over the BMC network) needs a per-node
  SFT-DCMS-SINGLE license.

## Pre-deployment (bare metal, no OS yet)

### Dell iDRACs — DSU remote mode

From a Linux workstation that can reach the iDRAC VLAN:

```bash
# Install DSU once: download the DSU Linux DUP from Dell support,
# chmod +x <file>.BIN && sudo ./<file>.BIN

# 1. Create the iDRAC list (keep this file private; it is NOT in the repo):
printf 'pve01 10.10.10.11\npve02 10.10.10.12\npve03 10.10.10.13\n' > /root/idracs.txt
chmod 600 /root/idracs.txt

# 2. Preview what each node needs:
export IDRAC_USER=root IDRAC_PASS='...'
scripts/update_firmware.sh dell --via idrac --idrac-list /root/idracs.txt --mode check

# 3. Apply, one iDRAC at a time (the script processes the list serially):
scripts/update_firmware.sh dell --via idrac --idrac-list /root/idracs.txt --mode apply --reboot
```

`--reboot` lets staged updates (BIOS, iDRAC) take effect immediately. Without
it, reboot each node through iDRAC after staging. Do all three Dells before
generating ISOs or deploying.

Alternative with no DSU: iDRAC Lifecycle Controller → Firmware Update from
Dell's online catalog, per node.

### Supermicro (pbs01) — BMC web UI + UEFI shell

Board is the **X10DRi** (E-ATX, C612, AST2400 BMC) in the 6028R-E1CR24N
chassis — confirmed 2026-09-25.

1. Download the latest X10DRi BIOS and BMC firmware from Supermicro's
   X10DRi product page.
2. BMC: web UI → Maintenance → Firmware Update (no license needed).
3. BIOS: boot the UEFI shell from USB and run the board's `flash.nsh`
   (or wait until PBS is installed and use SUM in-band, below).

## Ongoing cadence (quarterly suggested)

### Dell PVE nodes — DSU locally, one node at a time

```bash
# On pve01 first:
scripts/update_firmware.sh dell --via local --mode check
scripts/update_firmware.sh dell --via local --mode apply --reboot
```

Then verify cluster quorum and guest health before moving to pve02, and so
on. Never update/reboot multiple cluster nodes in parallel.

### Supermicro pbs01 — SUM in-band

```bash
# Download SUM from Supermicro (free registration) and the board's BIOS/BMC images.
scripts/update_firmware.sh supermicro --mode check --sum-bin /opt/sum/sum
scripts/update_firmware.sh supermicro --mode apply --sum-bin /opt/sum/sum \
  --bmc-file /opt/fw/SMCI_BMC.rom --bios-file /opt/fw/BIOS.rom --reboot
```

The script flashes **BMC first, then BIOS** — never both at once — preserves
BIOS settings, and pauses after the BMC update so you can confirm the BMC is
reachable again before touching the BIOS.

## OS drivers vs device firmware

"Keeping drivers up to date" has two halves:

- **Device firmware** (iDRAC/BMC, BIOS, NIC, PERC/HBA): DSU and SUM, above.
- **OS drivers**: on Proxmox VE these ship with the kernel and Debian
  `firmware-*` packages, so they are covered by regular Proxmox updates
  (`automation/ansible/rolling-update.yml` does this node-serially with
  quorum gates). No separate driver tool is needed on the Proxmox side.

## As-built status — R640 nodes (2026-11-01)

Check-only pass against the Dell catalog on 2026-10-31:

| Component | pve01 | pve02 | Catalog latest |
|---|---|---|---|
| BIOS | 2.24.0 | 2.24.0 | 2.29.2 |
| iDRAC / Lifecycle Controller | 7.00.00.181 | 7.00.00.182 | 7.00.00.185 (final 14G build) |
| PERC H730 Mini | 25.5.9.0001 | 25.5.9.0001 | 25.5.9.0001 — final release, current |
| NIC (rNDC) | update offered | update offered | Family 25.0 |

Dell maintains iDRAC9 software for 14G until 2027-02-01. The
ConnectX-3 40G cards are end-of-life and not catalog-managed.

**Update attempt 2026-10-31 — failed, nothing applied.** Every RACADM
update job (iDRAC, BIOS, NIC — both nodes) downloaded its package and
then failed **RED085** at Lifecycle Controller staging (LC log JCP042:
LC↔CMC communication timeout). A single test job on pve02 after
soft-resetting both iDRACs failed the same way, so the LC staging path
itself is wedged — the packages and the HTTP share they were served
from were hash-verified good. All firmware versions are unchanged;
nothing is half-applied.

**Agreed next step:** iDRAC-first via the iDRAC WebUI, starting with
pve02 to 7.00.00.185; BIOS and NIC follow only after the iDRAC update
lands. Fallback if the WebUI fails the same way: a flea-power drain in
a maintenance window. iDRAC SSH public-key authentication for `root`
is configured on both iDRACs (three key slots in use), so RACADM over
SSH works without a password via the Lenovo hop. pve03 (R440) and
pbs01 firmware baselines are still owed at their install time.

## Safety rules

- Stable power for the whole operation; run inside `tmux`/`screen` over SSH.
- Check mode first, every time. Read the preview before applying.
- One node at a time on the cluster; verify quorum between nodes.
- Supermicro: BMC before BIOS, never simultaneously.
- Prefer `IDRAC_USER`/`IDRAC_PASS` env vars over `--idrac-user`/`--idrac-pass`
  flags (flags land in shell history).

## As-built state (2026-11-03)

Both R640s are fully current after the 2026-11-03 firmware windows:

| Component | Version |
|---|---|
| iDRAC / Lifecycle Controller | 7.00.00.185 |
| BIOS | 2.29.2 |
| NIC firmware | 25.0 |
| PERC H730 Mini | 25.5.9.0001 (final) |

- **Method that works: WebUI upload** of the `.EXE` packages. The
  2026-10-31 RACADM remote-update attempts failed at LC staging
  (RED085); do not spend time there again. Packages are staged on the
  Lenovo at `~/dell-firmware/r640/`.
- **Boot modes differ per node and must be preserved at POST:**
  pve01 = UEFI, pve02 = Legacy. Verify after any BIOS update.
- The Mellanox ConnectX-3 40G NICs are EOL and not Dell-catalog
  managed; they stay on their current firmware.
- iDRAC housekeeping settled in the same window: DNS RAC names are
  `idrac-pve01` / `idrac-pve02`; `System.ServerOS.HostName` is
  `pve01` / `pve02` (PVE has no iSM, so these never auto-refresh —
  set them by hand after inventory changes); timezone US/Eastern;
  NTP 129.6.15.28 + 162.159.200.1.
- Dell ends 14G iDRAC9 maintenance on **2027-02-01**; 7.00.00.185 is
  effectively the end of the line.
