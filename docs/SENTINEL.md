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

## UCG Fiber interface gateways (owner screenshot)

| VLAN | Gateway |
| --- | --- |
| Default LAN | 192.168.1.1/23 |
| 10 OOB | 10.10.10.1/24 |
| 20 PVE management | 10.10.20.1/24 |
| 30 PBS management | 10.10.30.1/24 |
| 31 PBS backup | 10.10.31.1/24 |
| 40 Tailscale infrastructure | 10.10.40.1/24 |
| 41 Infrastructure services / Sentinel | 10.10.41.1/24 |
| 50 IoT | 10.10.50.1/24 |
| 60 Apple TV | 10.10.60.1/24 |
| 70 iPhones | 10.10.70.1/24 |
| 80 Wi-Fi AP management | 10.10.80.1/24 |
| 90 Printers | 10.10.90.1/24 |

**Design discrepancy:** VLAN 31 is gateway-managed on the UCG, while the topology describes an isolated backup fabric. Do not assume firewall isolation or change the live network until the routing and switch-port plan is reviewed. VLAN 100 remains third-party gateway with no UCG subnet shown. Trunk membership and firewall policy remain unverified.

## VLAN 100 VXLAN transport

UCG Fiber screenshot confirms `SDN_VXLAN_TRANSPORT` uses VLAN ID 100, router mode `Third-party Gateway`, and DHCP Guarding disabled. No UCG subnet or gateway is shown. Treat this as a Layer 2 transport on UCG; assign static, unique host IPs on the Proxmox VXLAN underlay interfaces after selecting a non-overlapping subnet, without a default gateway. Verify Nexus tagged VLAN 100 carriage and MTU end to end. This screenshot does **not** establish trunk profile membership or firewall policy.

## Catalyst 2960-X UCG trunk profile (owner screenshot)

Profile `TRUNK-TO-2960X-OOB`: port state Active, port mode Infrastructure, native VLAN/Network None, tagged VLAN management Custom, 8 selected tagged VLANs (identities not yet shown), Auto PoE enabled, Auto Negotiate enabled. **Do not assume UniFi native None equals Cisco native VLAN 998.** Confirm exact tagged VLAN list, untagged behavior, switch uplink configuration, and assigned physical port before cabling. Disable PoE on a dedicated switch uplink if supported and not needed. Nexus trunk profile remains unverified.

### Catalyst tagged VLAN evidence (owner screenshot)

The `TRUNK-TO-2960X-OOB` tagged-VLAN selector visibly checks **20, 30, 31, 41, 100** and leaves **1, 10, 40, 50, 60, 70, 80, 90** unchecked. The profile overview previously reported `8 Selected`, inconsistent with five visible checks; re-open and confirm saved state before changing the port. **VLAN 10 (OOB) is missing** from the visible selection and should be evaluated for the Catalyst uplink. VLANs 31 (PBS backup) and 100 (VXLAN transport) are unexpected on a dedicated OOB trunk and should be reviewed against the Nexus fabric design. VLAN 40 may be required if the Tailscale subnet router physically attaches to the Catalyst. This is a proposed review, not authorization to alter the UCG or switch.

### Subsequent eight-VLAN selection screenshot

A subsequent screenshot of a tagged-VLAN selector shows **10, 20, 30, 40, 50, 60, 70, 80** selected, with **1, 31, 41, 90, 100** unselected. The screenshot itself does not display the parent port-profile name, so confirm whether this is `TRUNK-TO-2960X-OOB` and whether changes were saved before replacing the earlier observed selection. If it is the Catalyst trunk, VLAN 10 is now present; VLAN 41 is absent and must instead reach `sentinel01` through the planned Nexus path or another explicitly designed uplink. Do not assume tagged VLAN membership establishes firewall reachability.
