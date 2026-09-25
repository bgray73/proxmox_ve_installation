# Proxmox Datacenter Manager (pdm01)

Single pane of glass over the PVE cluster and the PBS node. PDM 1.1
(May 2026) also brings centralized automated-install workflows with
answer files — a future consolidation target for this repo's
answer-server work (see the note at the bottom).

## Placement

| Field | Value |
|---|---|
| Name | `pdm01` |
| Type | VM (official PDM 1.1 ISO, Debian 13 based) |
| Node | `pve01` (HA enabled — survives a node failure) |
| VMID | `302` |
| vCPU / RAM / disk | 2 vCPU / 4 GB RAM / 32 GB disk |
| Network | VLAN 41 (infrastructure services) |
| IP | `10.10.41.22` static |
| Web UI | `https://10.10.41.22:8443` |

Why a VM and not an LXC: the ISO install is the most official,
least-fiddly path, and full virtualization keeps the management plane
isolated from the cluster hosts it manages. (An LXC with the
`proxmox-datacenter-manager-container-meta` package is a supported
lighter alternative if you ever want to trim overhead.)

## Build order

Deploy `pdm01` after cluster quorum is established and `pbs01` is
online — PDM manages remotes, so there must be remotes to manage.
It can go in alongside the other VLAN 41 infrastructure guests
(AdGuard, proxy, uptime, semaphore, ntfy).

## Wiring it up

1. Install from the PDM 1.1 ISO; set the static IP on VLAN 41 during
   install.
2. Log in at `https://10.10.41.22:8443` as `root@pam`.
3. Add remotes:
   - **PVE cluster** — point at any cluster node (VLAN 20, port 8006);
     use a dedicated API token with the minimum roles needed
     (read-mostly for dashboards; PDM 1.1 supports least-privilege
     remote tokens).
   - **pbs01** — VLAN 30, port 8007, same token discipline.
4. Firewall (UCG policy + PVE host firewall):
   - Allow `8443/tcp` to `10.10.41.22` from admin sources only
     (VLAN 20/30/41, Tailscale tailnet).
   - Allow `pdm01` → PVE nodes `8006/tcp` and → `pbs01` `8007/tcp`.
5. Confirm the cluster backup job covers VMID 302 (the default
   `--all` job in `docs/BACKUP-JOBS.md` picks it up automatically).

## Remote access

Reach PDM the same way as everything else: Tailscale → subnet router
(VLAN 40) → firewall policy → VLAN 41. Do not expose 8443 to the
Internet.

## Future: answer files

PDM 1.1 can act as a central configuration server for unattended
Proxmox installs (answer files served to new hosts, token-protected,
install progress tracked in the PDM UI). This overlaps with this
repo's answer-server work. Do **not** migrate yet — evaluate PDM's
workflow on the next node rebuild/reinstall and consolidate only if
it covers the host-aware logic the answer server currently provides.
