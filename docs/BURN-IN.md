# Hardware burn-in checklist

Run on **every node before** firmware updates (`docs/FIRMWARE.md`) and before
the Proxmox install. Goal: catch dead DIMMs, dying disks, and thermal problems
while replacements are still cheap and nothing is deployed yet.

Nodes: 3× Dell PowerEdge (2× R640, 1× R440) + 1× Supermicro (pbs01).
All have iDRAC/BMC on VLAN 10 — drive everything through virtual media and
remote console; no crash cart needed.

Run all four nodes **in parallel**. Wall-clock budget for the whole fleet:
roughly **2–4 days** (see time budget below).

## Per-node checklist

Copy this block once per node and fill it in.

```
Node:            pve0X / pbs01
Model:           _______________
Service tag / serial: _______________
Date started:    _______________
```

### 0. Baseline

- [ ] Record service tag/serial, BIOS version, iDRAC/BMC version.
- [ ] Note drive inventory: `lsblk` + model/serial per disk (from live Linux or iDRAC/BMC storage view).
- [ ] For SSDs/NVMe, snapshot SMART **before** testing (`smartctl -a`, `nvme smart-log`) — you need the before/after delta for wear.

### 1. Memory — memtest86+

- [ ] Mount the memtest86+ ISO (v7+, UEFI build) via iDRAC/BMC virtual media, boot it.
- [ ] Run **8 full passes**. On high-RAM systems where one pass takes many hours, a minimum of **4 passes or 24 hours** (whichever is longer) is the pragmatic floor.
- [ ] **Pass = 0 errors across all completed passes.** Any red line = fail.
- [ ] On failure: stop, reseat DIMMs and re-run once to rule out seating. If errors persist or follow a stick, replace/RMA the DIMM and **re-run the full memory test** on the replacement.
- [ ] Dell alternative: Lifecycle Controller (F10) → Hardware Diagnostics → extended memory test. Acceptable substitute; same 0-error rule.

### 2. Disks

Boot a Debian/Ubuntu live image via virtual media. **All tests below are destructive** — that is fine, these disks have no data yet. Target the raw block device (`/dev/sdX`, `/dev/nvme0n1`), never a partition.

**HDDs** — destructive badblocks, 4-pattern write test:

```bash
badblocks -b 4096 -c 1024 -s -v -w /dev/sdX
```

- [ ] 0 bad blocks reported. Any bad block = fail → replace the drive.
- [ ] Time guide: very roughly one day per 4 TB for the full 4-pattern run. In a hurry, `-w -t random` does a single random-pattern pass in ~¼ of the time — acceptable, note which you ran.

**SSDs / NVMe** — fio, sequential + random writes. Keep runs to **a few hours per pattern** and stay TBW-aware: check the SMART wear delta afterwards (`Percentage_Used` / `Media_Wearout_Indicator`); a burn-in should cost low single-digit percent at most.

```bash
# sequential write, 2h
fio --name=seq --filename=/dev/nvme0n1 --direct=1 --rw=write --bs=1M \
    --iodepth=32 --numjobs=4 --runtime=7200 --time_based --group_reporting
# random write, 2h
fio --name=rand --filename=/dev/nvme0n1 --direct=1 --rw=randwrite --bs=4k \
    --iodepth=64 --numjobs=8 --runtime=7200 --time_based --group_reporting
```

- [ ] No I/O errors in fio output, no new SMART errors (`smartctl -l error` / `nvme error-log`), no concerning wear jump.
- [ ] Vendor tools where handy (SeaTools, WD Dashboard, Samsung Magician) — optional, not a substitute.

### 3. CPU and thermals — stress-ng

From the same live Linux session (can run **concurrently** with the disk tests):

```bash
stress-ng --cpu 0 --cpu-method all --timeout 4h --metrics-brief
```

- [ ] 4 hours, no crashes, no kernel errors (`dmesg | grep -iE 'mce|error|fail'` clean afterwards).
- [ ] Watch temperatures throughout via iDRAC/BMC sensor readings (`racadm getsensorinfo` or the web UI). Investigate any sensor sitting in warning/critical state, any thermal throttling, or any fan stuck at full tilt with no corresponding temperature cause.
- [ ] mprime (prime95) torture test is an acceptable alternative; same 4-hour rule.

### 4. Sign-off per node

- [ ] Memory: passes / errors: ___ / ___
- [ ] Disks: per-drive result: ___
- [ ] CPU/thermals: result, peak temps noted: ___
- [ ] SMART after (SSDs): wear delta sane, no new errors: ___
- [ ] Overall: **PASS / FAIL**, date, operator initials: ___

## The one rule

**Any failure = stop that node, replace or RMA the faulty part, and re-run the
full burn-in on the replacement.** Do not "retire" a suspect DIMM by leaving
the slot empty and calling it good, and do not promote a node with a known-bad
disk to the cluster. A flaky component found in week one of production costs
ten times what it costs now.

## Time budget (per node, all nodes run in parallel)

| Phase | Typical duration |
|---|---|
| Memory (memtest86+, 8 passes) | 6–24 h depending on RAM size |
| Disks (badblocks HDD or fio SSD) | 4–24 h depending on size/type |
| CPU/thermal (stress-ng) | 4 h, overlaps disk tests |
| **Total per node** | **~1–3 days** |

Plan a long weekend. When every node signs off PASS, move on to
`docs/FIRMWARE.md`.
