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
printf 'pve01 10.10.10.11\npve02 10.10.10.12\npve03 10.10.10.13\npve04 10.10.10.14\n' > /root/idracs.txt
chmod 600 /root/idracs.txt

# 2. Preview what each node needs:
export IDRAC_USER=root IDRAC_PASS='...'
scripts/update_firmware.sh dell --via idrac --idrac-list /root/idracs.txt --mode check

# 3. Apply, one iDRAC at a time (the script processes the list serially):
scripts/update_firmware.sh dell --via idrac --idrac-list /root/idracs.txt --mode apply --reboot
```

`--reboot` lets staged updates (BIOS, iDRAC) take effect immediately. Without
it, reboot each node through iDRAC after staging. Do all four Dells before
generating ISOs or deploying.

Alternative with no DSU: iDRAC Lifecycle Controller → Firmware Update from
Dell's online catalog, per node.

### Supermicro (pbs01) — BMC web UI + UEFI shell

1. Identify the exact board model first (the example inventory still says
   `CHANGE_ME_MODEL`; fill in the real model).
2. Download the matching BIOS and BMC firmware from Supermicro for that board.
3. BMC: web UI → Maintenance → Firmware Update (no license needed).
4. BIOS: boot the UEFI shell from USB and run the board's `flash.nsh`
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

## Safety rules

- Stable power for the whole operation; run inside `tmux`/`screen` over SSH.
- Check mode first, every time. Read the preview before applying.
- One node at a time on the cluster; verify quorum between nodes.
- Supermicro: BMC before BIOS, never simultaneously.
- Prefer `IDRAC_USER`/`IDRAC_PASS` env vars over `--idrac-user`/`--idrac-pass`
  flags (flags land in shell history).
