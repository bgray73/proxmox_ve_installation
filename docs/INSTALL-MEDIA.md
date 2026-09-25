# Install media (Ventoy USB)

One USB stick, all installers. 16 GB+ USB 3 stick with Ventoy; drop the
ISOs below on it and pick at boot.

## ISOs

Snapshot of current versions and hashes as of **2026-09-25**, from the
official `SHA256SUMS` at `https://enterprise.proxmox.com/iso/SHA256SUMS`.
Proxmox re-spins ISOs on point releases, so **re-verify at download
time** — the signed `SHA256SUMS` is the source of truth, this table is
a convenience snapshot.

| ISO | Version | SHA256 | Used for |
|---|---|---|---|
| `proxmox-ve_9.2-1.iso` | PVE 9.2 | `4e88fe416df9b527624a175f24c9aa07c714d3332afb1ee3dbf3879573ef2c6c` | pve01–pve03 |
| `proxmox-backup-server_4.2-1.iso` | PBS 4.2 | `2fb299deac3929253712c9c3dfc9237edbe70af83c8848467616b771a1d5453e` | pbs01 |
| `proxmox-datacenter-manager_1.1-1.iso` | PDM 1.1 | `11a55a069ba564220bd986241b57920a83781d40be18d6f2bf7b9b12696ae2cc` | pdm01 VM (via cluster ISO upload or virtual media) |

## Verify before you trust

```bash
# Release key (trixie); confirm fingerprint before trusting it
wget https://enterprise.proxmox.com/debian/proxmox-release-trixie.gpg
gpg --show-keys ./proxmox-release-trixie.gpg
# must show: 24B30F06ECC1836A4E5EFECBA7BCD1420BFE778E

# Verify the signed checksum file, then the ISOs
wget https://enterprise.proxmox.com/iso/SHA256SUMS{,.asc}
gpgv --keyring ./proxmox-release-trixie.gpg SHA256SUMS.asc SHA256SUMS
sha256sum -c SHA256SUMS   # only the three ISOs above need to say OK
```

## Ventoy notes

- Install Ventoy on the stick, then copy the ISOs into it as plain
  files — no imaging step.
- **Secure Boot:** on first boot from the stick, enroll Ventoy's MOK
  key when prompted, or disable Secure Boot in the host BIOS.
  The Dells and the Supermicro will each prompt once.
- Alternative for the Dells: iDRAC virtual media mounts an ISO
  remotely with no USB involved. The Supermicro IPMI has virtual
  media too. Ventoy is still the simplest single path for all four
  machines.
- Keep the stick after the build — it is your reinstall media for
  disaster recovery (`docs/DISASTER-RECOVERY.md`).
