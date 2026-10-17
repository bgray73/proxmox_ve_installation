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

### Confirmed saved Catalyst profile

Owner confirms the later eight-VLAN selection is **saved** under `TRUNK-TO-2960X-OOB`: tagged VLANs **10, 20, 30, 40, 50, 60, 70, 80**; excluded **1, 31, 41, 90, 100**. This supersedes the earlier five-VLAN screenshot for the Catalyst profile. The native VLAN is shown as `None` in the profile overview; its untagged behavior and compatibility with Cisco native VLAN 998 still require verification. Nexus trunk profile remains to be inspected.

### Nexus trunk tagged-VLAN selector (owner screenshot)

The latest screenshot, supplied in response to the Nexus trunk request, visibly selects VLANs **20, 30, 31, 41, 100** and excludes **10, 40, 50, 60, 70, 80, 90** (VLAN 1 partly obscured). The screenshot does not display the parent profile name or confirm the selection was saved. Confirm it is `TRUNK-TO-NEXUS-CORE` and saved before treating this as the deployed uplink configuration. VLAN 41 is selected for planned Sentinel service traffic; VLAN 31 on the UCG-facing trunk should be reviewed because the backup network was intended to be isolated. Native VLAN and physical port assignment remain unverified.

### Confirmed saved Nexus profile

Owner confirms the five-VLAN selector screenshot is **saved** under `TRUNK-TO-NEXUS-CORE`: tagged VLANs **20, 30, 31, 41, 100**. VLANs **10, 40, 50, 60, 70, 80, 90** are excluded. This is the intended UCG-to-Nexus profile, not evidence of switch-side configuration or physical port assignment. **Open checks:** native VLAN/untagged handling, Nexus port trunk allowed VLANs, UCG port assignment, and whether VLAN 31 needs to traverse the UCG uplink.

### Confirmed UCG-to-Nexus profile overview

Owner screenshot shows `TRUNK-TO-NEXUS-CORE`: Active; Infrastructure mode; **Native VLAN / Network = None**; Tagged VLAN Management = Custom; **5 Selected** (previously confirmed saved VLANs 20,30,31,41,100); Auto PoE enabled; Auto Negotiate enabled. Switch-side candidate configuration: trunk with allowed VLANs `20,30,31,41,100`, actual interface TBD. **Do not treat UniFi native `None` as proof that untagged frames are dropped or that Cisco native VLAN 998 matches.** Confirm untagged behavior and physical port mapping before applying a native VLAN policy. Consider disabling PoE on the switch uplink after confirming port capabilities. No live configuration changed.

### Planned Nexus-to-UCG physical uplink (not installed)

Owner preference: reserve the **last 10GbE copper/RJ45 port** on the Nexus 9K for a 10GbE link to an available 10GbE RJ45 LAN port on UCG Fiber. Exact Nexus model, interface number, UCG LAN port, cabling and negotiated speed are **TBD** until hardware inspection. Use the confirmed UCG `TRUNK-TO-NEXUS-CORE` tagged VLANs **20,30,31,41,100** on this uplink, subject to review of whether PBS backup VLAN 31 should reach UCG. UniFi native VLAN `None` must be reconciled with switch-side native VLAN/untagged behavior before applying configuration. Do not assign `Ethernet1/48` or another guessed interface, and do not change live switch settings yet.

### Nexus hardware identification and reserved uplink

Owner-provided listing identifies **Cisco Nexus N9K-C9372TX** (48 × 1/10GBASE-T RJ45 and 6 × 40GbE QSFP+). Reserve **Ethernet1/48**, the last 10GbE copper port, for the planned 10GbE UCG Fiber uplink. The UCG port number, native/untagged behavior, cabling, and live link speed remain to be confirmed. Tagged VLANs in the saved UCG profile: 20,30,31,41,100. This is a reservation, not an applied NX-OS configuration.

Candidate NX-OS configuration for review only:

```text
vlan 20,30,31,41,100
interface Ethernet1/48
  description UPLINK-TO-UCG-FIBER
  switchport
  switchport mode trunk
  switchport trunk allowed vlan 20,30,31,41,100
  no shutdown
```

Before applying, verify hardware port labeling and choose an explicit native VLAN policy compatible with UniFi `None`; consider removing VLAN 31 from the UCG uplink if backup traffic is intended to remain isolated.

### Tentative UCG Fiber port and copper SFP+ uplink

Owner is considering **UCG Fiber port 6 or 7** for the Nexus uplink, with a **10GBASE-T RJ45 SFP+ transceiver** in the UCG and Cat6a to Nexus **Ethernet1/48**. **Do not finalize port 6/7** until the UCG Fiber port map confirms that the chosen port is a 10Gbps LAN-capable SFP+ cage (not WAN-only or otherwise assigned). Check Ubiquiti transceiver support, module power/thermal limits, and copper cable distance before purchasing. Alternative: use an available built-in 10GbE RJ45 LAN port if supported, avoiding an SFP+ copper module. This is a planned connection, not deployed.

### UCG Fiber port selection (owner device screenshot)

Current device overview shows **port 5 connected at 10 GbE** (uplink), **port 6 disconnected with SFP label**, and **port 7 disconnected with WAN/globe icon**; port 3 has an active GbE connection. Preferred Nexus connection is **UCG Fiber port 6 SFP+ → 10GBASE-T RJ45 SFP+ transceiver → Cat6a → Nexus C9372TX Ethernet1/48**. Before procurement, verify port 6 supports 10G LAN mode and the specific copper SFP+ module's compatibility, power, thermal requirements and supported cable length. Keep port 5's existing uplink and port 7's WAN designation unchanged. No physical link or switch configuration has been changed.

### Planned UCG-to-Catalyst OOB uplink (owner approved)

Reserve **UCG Fiber port 1 → Cisco Catalyst 2960-X OOB uplink port (exact Cisco interface TBD)** using a 1GbE RJ45 Ethernet link, subject to confirming port 1 is free and LAN-capable. Assign saved UCG profile `TRUNK-TO-2960X-OOB` to port 1: tagged VLANs **10,20,30,40,50,60,70,80**, native network **None**. Configure the corresponding Catalyst port as an 802.1Q trunk with matching allowed VLANs, but first validate untagged/native VLAN handling (Cisco VLAN 998 is only a candidate). Disable PoE on the UCG uplink if supported and unnecessary. Do not also interconnect Catalyst and Nexus without a reviewed Layer 2 topology and loop-prevention plan. This reservation is **planning only**, not an applied configuration.

Combined planned uplinks: **UCG port 1 → Catalyst OOB (1GbE)**; **UCG port 6 SFP+ → 10GBASE-T module → Nexus C9372TX Ethernet1/48 (10GbE)**. UCG port 5 remains in its current role. Confirm physical port assignment and firewall policies before cabling.

### Catalyst uplink interface reservation

Owner selects the **last copper Ethernet port on the Cisco Catalyst 2960-X** as the UCG uplink, connected to **UCG Fiber port 1**. Exact Catalyst interface designation is pending confirmation of the switch's 24- versus 48-port model and port numbering; do not guess `Gi1/0/24` or `Gi1/0/48`. Configure that port as a trunk with tagged VLANs **10,20,30,40,50,60,70,80** and reconcile native/untagged VLAN behavior with the UCG profile before deployment. This is a planned cable assignment only.

### Catalyst model refinement: 48-port PoE

Owner confirms the Catalyst 2960-X is a **48-port PoE** variant. For a standalone unit with standard numbering, reserve **GigabitEthernet1/0/48** (last copper access port) for **UCG Fiber port 1**. Verify the exact PID, interface list and stack member numbering using `show version` and `show interfaces status` before applying. PoE capability does not mean PoE should be used on this switch-to-switch link: disable PoE on the Catalyst uplink with `power inline never` if supported, and disable UCG port 1 PoE if configurable. The tagged VLANs remain 10,20,30,40,50,60,70,80; native VLAN remains subject to compatibility validation. No live changes performed.

### UCG Catalyst uplink port revision (owner preference)

**Supersedes earlier reservation of UCG Fiber port 1:** Owner prefers a **non-PoE UCG LAN port** for the Catalyst 2960-X 48-port PoE uplink. **UCG port 2 is a tentative candidate only**, pending confirmation from the UCG port map that it is non-PoE, LAN-capable, and free. Keep **Catalyst Gi1/0/48** reserved for the switch end. Existing `TRUNK-TO-2960X-OOB` VLAN set (10,20,30,40,50,60,70,80) unchanged; native VLAN verification outstanding. Do not cable or configure UCG port 1 for this uplink based on older documentation.
