# Sentinel integration contract

**Status:** Planning only. No Proxmox hosts are deployed. The owner supplied a UCG Fiber screenshot confirming VLAN 10 (10.10.10.0/24), 20 (10.10.20.0/24), 30 (10.10.30.0/24), 31 (10.10.31.0/24), 40 (10.10.40.0/24), 41 (10.10.41.0/24), 50 (10.10.50.0/24), 60 (10.10.60.0/24), 70 (10.10.70.0/24), 80 (10.10.80.0/24), and 90 (10.10.90.0/24). The owner also supplied a UCG overview showing VLAN 100 as a third-party-gateway network with no displayed subnet, custom port profiles TRUNK-TO-2960X-OOB and TRUNK-TO-NEXUS-CORE, and an enabled Home WireGuard VPN displaying 10.20.30.1/24. Trunk allowed VLANs, native VLAN, port assignment, gateway addresses, firewall policies, and live reachability remain unverified. This repo owns the LXC resource and VLAN placement; [sentinel-lab](https://github.com/bgray73/sentinel-lab) owns the application and its configuration.

| Setting | Contract |
| --- | --- |
| Host | pve01 (Dell R640) |
| Guest | sentinel01 |
| Type | Unprivileged Debian 13 LXC, native Node.js |
| Capacity | 2 vCPU, 4096 MiB RAM, 512 MiB swap, 32 GiB SSD-backed disk |
| Network | VLAN 41 infrastructure services (10.10.41.0/24), routed to PVE API on VLAN 20 (10.10.20.0/24) |
| CTID, IP, storage, bridge | TBD after host/network provisioning |
| Startup | On boot; provision stopped for review |
| Authentication | Loopback-only app until protected behind authenticated reverse proxy |
| Proxmox API | Dedicated read-only PVEAuditor token; TLS verification enabled |
| Docker | No socket or Docker-in-LXC for initial release |
| Actions | SENTINEL_ENABLE_WORKLOAD_ACTIONS=false |

## Ownership and dependencies

1. Follow `docs/BUILD-ORDER.md` through network, PVE installation, cluster, and backup prerequisites.
2. Reuse the already configured UCG Fiber VLANs. Verify the VLAN 41 gateway, firewall policy, and management bridge after the hosts are connected. **VLAN 41 must be able to reach the Proxmox API on VLAN 20 TCP 8006**; avoid Corosync VLAN 21 and PBS backup VLAN 31.
3. Validate an unused cluster CTID and SSD-backed rootdir storage. Reserve an address for sentinel01 only after DHCP/VLAN configuration is known.
4. Review the [Sentinel LXC plan](https://github.com/bgray73/sentinel-lab/blob/main/docs/sentinel-dedicated-lxc.md) and [draft provisioning PR #34](https://github.com/bgray73/sentinel-lab/pull/34). The Sentinel repository currently owns the guarded provisioning script; migrate or invoke it from this repository only after one canonical owner is selected, to avoid diverging copies.
5. Create the stopped container, review its network and security settings, then start it and install Sentinel natively.
6. Confirm API discovery for pve01, pve02, pve03, and workloads. Configure PBS telemetry later with a separate least-privilege credential.
7. Add the guest to the appropriate PBS backup policy, test restoration, and record its version/configuration in the infrastructure inventory.

## Cross-repository change checklist

- Host/CTID/bridge/VLAN/storage changes: update this document and the Sentinel LXC worksheet in the same change window.
- Application env/ports/auth/secret changes: update Sentinel first, then verify the firewall and proxy assumptions here.
- Security: never commit API secrets, private certificates, or live management addresses without explicit review.
- Deployment: neither repo's CI should automatically run `pct create` or deploy onto a live node.
