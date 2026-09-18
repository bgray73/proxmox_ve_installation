# Scanopy on Proxmox

This is a deployment and validation runbook for the Dell 42U home lab. **Status: planned; Scanopy has not been installed or scanned by this repository.** The source of truth for rack U positions and power is [RACK-LAYOUT.md](RACK-LAYOUT.md). Scanopy will supply the observed network and service topology.

## Placement

Create a small Debian VM on one of the Dell Proxmox VE nodes for Docker Engine and Compose V2; do not install Docker on the PVE host. Put the VM on the infrastructure/monitoring network with a stable address and DNS entry. Allocate at least 4 GB RAM and 20 GB persistent disk to start, then increase after measuring scans and PostgreSQL growth. Back up the VM with the independent Supermicro PBS. Avoid placing the sole scanner on an isolated VM segment it cannot route out of.

The free self-hosted Community Edition supports one network and one user seat. Here a Scanopy **network** is the rack site; add the intended management and data subnets as scan targets according to routing and the edition's limits. Treat the repo's `10.10.x.x` and `192.0.2.x` addresses as examples, not a live IP plan. Never scan the Corosync-only VLAN 21 or backup-only VLAN 31 just to complete a diagram.

## Install

In the Debian VM, install Docker Engine and Compose V2 using Docker's official instructions. Download and **review the current upstream Compose file** from Scanopy before launching; it includes the server, PostgreSQL and an integrated scan daemon. Keep the Compose file and database volume on persistent VM storage, and back them up. The upstream `main` file changes over time, so record the version or commit used.

```bash
mkdir -p /opt/scanopy && cd /opt/scanopy
curl -fsSLo docker-compose.yml https://raw.githubusercontent.com/scanopy/scanopy/refs/heads/main/docker-compose.yml
# Review image versions, volumes, ports, environment and daemon target before starting.
docker compose config
docker compose up -d
docker compose ps
```

Open `http://<scanopy-vm-ip>:60072` from the management network and create the initial account. Restrict UI access to management clients or Tailscale through the firewall; do not forward port 60072 from the Internet. Before first registration, confirm the integrated daemon URL in the upstream Compose file matches the VM's Docker bridge gateway; Scanopy's default documentation assumes `172.17.0.1`. If it differs, adjust `SCANOPY_INTEGRATED_DAEMON_URL` before registration. Keep PostgreSQL and daemon ports limited to the VM/required internal paths.

## Discover the rack

1. Start with narrow scan targets: UCG Fiber, Nexus 9372TX, Catalyst 2960-X, `pve01`–`pve03`, `pbs01`, iDRAC/IPMI and the Scanopy VM. Use the real addresses from your private inventory. Add routed segments only after firewall reachability is verified.
2. On the Nexus and Catalyst, enable LLDP and read-only SNMPv3 AuthPriv credentials where supported. Permit the daemon to reach UDP 161. Enter credentials in Scanopy **Assets → Credentials**, never in Git. Scanopy reads LLDP/CDP neighbor tables over SNMP for its L2 Physical view.
3. If UCG Fiber controller discovery is wanted, follow Scanopy's UniFi integration and scope its credentials. Do not assume Scanopy will identify every server-side port: endpoints that do not expose neighbor data may be absent from L2 Physical.
4. Run a discovery, inspect host identities and interfaces, and compare L2 links to [PORT-MAP.md](../network/PORT-MAP.md). The intended links are three Dell 40G primary DACs plus one PBS 40G DAC on the Nexus, Dell 10G failover to Nexus, and iDRAC/IPMI and 1G management to Catalyst. Verify actual Nexus QSFP+ interface numbers on the installed switch; logical port labels in the port map are placeholders.
5. Review L3 and workload views for the Proxmox and PBS hosts; document any missing links rather than drawing an unverified connection. Export the validated topology as SVG or Mermaid and add a dated copy under `docs/` when the first real scan exists. Keep credentials, serials and private addresses out of this public repo.

## What Scanopy cannot determine

A network scan does not reveal front/rear U placement, patch-panel position, UPS feed, PDU outlet or power-cord destination. Maintain those fields in [RACK-LAYOUT.md](RACK-LAYOUT.md), and verify them physically. A discovered cable-level connection is evidence of observed topology, not proof that the proposed rack plan was installed.

## References

- [Scanopy self-hosted install](https://scanopy.net/docs/self-hosted-server/server-installation/)
- [Scanopy L2 Physical view](https://scanopy.net/docs/using-scanopy/topology/l2-physical/)
- [Scanopy SNMP discovery](https://scanopy.net/docs/guides/integrations/snmp/)
- [Scanopy daemon deployment](https://scanopy.net/docs/setting-up-daemons/planning-daemon-deployment/)
