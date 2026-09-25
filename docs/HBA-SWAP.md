# 9300-8i swap runbook (pbs01)

Replace the Broadcom 3108 hardware-RAID mezzanine (Supermicro
AOM-S3108M-H8) with the LSI/Broadcom SAS 9300-8i in IT mode, so ZFS
gets direct disk access on pbs01 (Supermicro 6028R-E1CR24N, X10-series
board, 24 front LFF bays + 2 rear flex bays).

**The single most important step is Step 1.** Everything else depends
on what backplane is actually in the chassis.

## Parts checklist

- [ ] 9300-8i, confirmed IT-mode firmware (see Step 4)
- [ ] Low-profile bracket fitted (2U chassis — full-height will not fit)
- [ ] SFF-8643 → SFF-8643 cables (count per Step 1; buy 2)
- [ ] 2.5"→3.5" adapter trays for the front SSDs
- [ ] ESD strap; phone camera for "before" photos
- [ ] Labels/tape for the old cables

## Step 0 — Before shutdown (3108 still installed)

While the machine still boots on the old controller:

- [ ] Photograph the interior: mezzanine card, every SAS cable route,
      both ends of each cable.
- [ ] Record `lspci | grep -i -E "lsi|broadcom"` and how the OS
      currently sees disks (`lsblk`, `/dev/disk/by-id/`).
- [ ] Note which cables run mezzanine → backplane, and how the **rear
      flex bays** are cabled (they are often on onboard SATA, not the
      3108 — leave that cabling alone; those bays hold the PBS OS
      mirror).
- [ ] Check the 3108 for a CacheVault/supercap module — it comes out
      with the card.

## Step 1 — Identify the backplane (power off, lid open)

Find the model printed on the backplane PCB. This decides the cabling:

- **Expander backplane** (e.g. `BPN-SAS3-826EL1`): has a SAS expander
  chip. One 9300-8i covers **all 24 bays** through the expander —
  connect both SFF-8643 HBA ports to the backplane's primary uplink
  ports. This is the expected case for this chassis.
- **Direct-attach backplane** (e.g. `BPN-SAS3-826A`): no expander, one
  connector per 4 bays. A 9300-8i only covers **8 bays** here —
  **stop**. Do not proceed; reassess (options: second HBA,
  9300-16i-class card, or different chassis plan).

Record the backplane model in `inventory.json` regardless.

## Step 2 — Remove the 3108 mezzanine

- [ ] Power off, unplug both PSUs, ESD strap on.
- [ ] Disconnect and **label** every SAS cable on the mezzanine card.
- [ ] Remove the standoff screws and lift the AOM-S3108M-H8 straight
      off its mezzanine connector. Keep the card and its cables
      labeled as the rollback kit.

## Step 3 — Install the 9300-8i

- [ ] Confirm the low-profile bracket is fitted.
- [ ] Install in a PCIe 3.0 **x8 or x16** slot (the card is x8
      electrically). Prefer a CPU-attached slot; keep it clear of the
      10Gb NIC if lane layout forces a choice — check the board
      manual silkscreen.
- [ ] Connect SFF-8643 HBA ports → backplane primary uplink ports
      (expander case). Route cables for airflow; they must not press on
      DIMMs or the heatsinks.

## Step 4 — Verify the card's firmware (before closing the lid)

Boot the Ventoy stick to a UEFI shell (or any EFI shell):

```
sas3flash.efi -list
```

- [ ] Confirm **IT (Initiator-Target) firmware**, not IR.
- [ ] Record the SAS address shown.
- If the card arrived in IR mode, flash IT firmware first (see the
  [9300-8i IT-mode guide](https://github.com/EverLand1/9300-8i_IT-Mode)):
  record the SAS address **before** erasing, flash
  `SAS9300_8i_IT.bin`, then restore the address with
  `sas3flash.efi -o -sasadd <address>`. Do not power off mid-flash.

## Step 5 — BIOS checks

- [ ] BIOS lists the SAS3008-based 9300-8i on the PCIe inventory.
- [ ] Disable any 3108 option ROM / "onboard SAS" boot entries left
      over from the mezzanine.
- [ ] **Disable boot support on the HBA itself** (HBA BIOS/UEFI boot) —
      nothing boots from it, and this avoids option-ROM boot delays.
- [ ] Boot order: rear flex-bay SSD OS mirror first.

## Step 6 — IPMI/BMC checks

(pbs01 is Supermicro — this is IPMI/BMC, not iDRAC; iDRAC applies to
the Dell PVE nodes.)

- [ ] IPMI web UI reachable; no new critical sensor events.
- [ ] Fan speeds and temps sane after the swap (the HBA adds a few
      watts; watch the PCIe zone temp).

## Step 7 — OS verification (PBS 4.2)

- [ ] `lspci` shows the SAS3008; `dmesg | grep mpt3sas` shows the
      driver attaching with no errors.
- [ ] **Every disk appears as an individual device** with its real
      model/serial: `ls -l /dev/disk/by-id/`, `lsscsi`.
- [ ] Per-disk SMART works through the HBA: `smartctl -a /dev/sdX`
      for each disk. This is the proof there is no RAID layer left.
- [ ] Record every model/serial/slot in `inventory.json`.

## Step 8 — Burn-in before pool creation

- [ ] `smartctl -t short` then `-t long` on every disk; zero errors.
- [ ] Spot-check with `badblocks` or `fio` per `docs/BURN-IN.md`.
- [ ] Only then create pools per `docs/PBS-STORAGE.md`.

## Rollback

If the 9300-8i is DOA or the backplane turns out to be direct-attach:
reinstall the labeled 3108 mezzanine and its cables exactly as
photographed in Step 0. Nothing is destroyed by the swap attempt —
no pools exist yet.
