# Secure remote appliance management

## Recommendation: Tailscale subnet router

Use Tailscale on one dedicated, patched Linux appliance (two later for resilience) and advertise only the iDRAC/BMC and PVE/PBS management subnets. A subnet router lets tailnet clients reach devices that cannot run Tailscale themselves, which fits iDRAC and switch management.[3] Use Tailscale grants to restrict the source group, destination CIDRs, and ports.[4]

Do **not** expose TCP 8006/8007, SSH, iDRAC HTTPS, Redfish, IPMI, or the Nexus management plane directly to the Internet. Do not install Tailscale directly on PVE nodes as the only recovery path; a broken cluster should not remove remote iDRAC access. Prefer a small physical Debian appliance with independent power. Two appliances on separate power are better, though the single Nexus remains a shared failure domain.

### Why not Pangolin as the primary tool?

Pangolin is a tunneled identity-aware reverse-proxy platform and is attractive for publishing selected web applications.[5] It is less natural for the full appliance workflow: SSH, Redfish/IPMI, virtual console ports, arbitrary management protocols, and full-subnet reachability. It can complement Tailscale for browser-only apps, but it should not replace the management VPN here.

### Alternatives

- **Headscale:** self-hosted Tailscale control plane; more ownership and maintenance. Choose it only if avoiding the hosted coordination service outweighs simplicity.
- **NetBird:** strong WireGuard-based alternative with self-hosting; reasonable if its management model is preferred.
- **Plain WireGuard:** smallest dependency set, but routing, peer lifecycle, ACLs, DNS, and key rotation become your responsibility.

## Deployment

1. Put the router appliance on infrastructure-services VLAN 40 with tightly filtered firewall routes to VLAN 10 (iDRAC), VLAN 20 (PVE management), and VLAN 30 (PBS management). Do not advertise Corosync or backup-data VLANs.
2. Copy and customize `tailscale-policy.example.hujson` in the Tailscale admin console.
3. Run the installer and complete its interactive Tailscale login (no auth key is stored in shell history):

   ```bash
   sudo remote-access/install_tailscale_router.sh \
     '10.10.10.0/24,10.10.20.0/24,10.10.30.0/24'
   ```

4. Approve the advertised routes.
5. Test as an authorized admin, then test from an unauthorized identity.
6. Keep local console/recovery credentials in an offline password manager.

The sample grant permits only common management ports. Confirm actual iDRAC virtual-console requirements for your firmware; remove every port you do not need. Add Nexus SSH/HTTPS only if the switch management IP is inside an advertised management prefix and explicitly permitted.

### Tighter scope with host routes

For tighter scope, replace the three `/24` routes with explicit `/32` routes for each iDRAC, PVE/PBS management address, and the Nexus management address. Example:

```bash
sudo remote-access/install_tailscale_router.sh \
  '10.10.10.11/32,10.10.10.12/32,10.10.20.11/32,10.10.20.12/32,10.10.30.20/32'
```

Keep at least one subnet router on a physical, independently powered Linux appliance so cluster failure does not remove the recovery path; add a second appliance later for resilience.[3]

### Break-glass path

Always retain a non-Tailscale recovery path:

- Local keyboard/monitor or serial console on the subnet-router appliance
- iDRAC/BMC virtual console credentials stored offline
- Documented physical access procedure for the rack

Tailscale is the day-to-day path, not the only path.

## Sources

[3] https://tailscale.com/kb/1019/subnets — Tailscale subnet routers
[4] https://tailscale.com/kb/1337/acl-syntax — Tailscale access controls
[5] https://docs.pangolin.net/about/how-pangolin-works — Pangolin architecture
