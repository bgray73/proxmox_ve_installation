# Templates (optional)

Post-install helpers for building reusable **guest** images on an existing Proxmox cluster.

These are **not** required for PVE/PBS automated installation (ISOs, answer server, first-boot).

| Path | Description |
|------|-------------|
| [`cloud-init/`](cloud-init/) | Create Ubuntu (or similar) cloud-init golden templates with `qm`, plus vendor snippet example |

Typical order of operations:

1. Install and cluster PVE with this repo's main flow.
2. On a PVE node, build a cloud-init template (`templates/cloud-init/`).
3. Clone VMs (UI, `qm clone`, or Ansible `community.proxmox`) and configure guests.
