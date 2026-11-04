# Scanopy on Proxmox

This is a deployment and validation runbook for the Dell 42U home lab. **Status: deployed 2026-10-30** — VM 305 `scanopy-01` on pve02 (2 vCPU, 4 GB RAM, 32 GB disk, static 10.10.41.25 on VLAN 41), Docker Engine + Compose installed, upstream `docker-compose.yml` (fetched from `main` 2026-10-30) running unmodified at `/opt/scanopy` except a `.env` setting `SCANOPY_PUBLIC_URL=http://10.10.41.25:60072`. All three containers (server, daemon, postgres) verified healthy and the UI answers at `http://10.10.41.25:60072`. SNMP side (2026-10-30): read-only SNMPv2c is enabled on both switches (Nexus community configured + config saved; Catalyst community pre-existed behind ACL 20, which now also permits 10.10.41.25; LLDP active on both, configs saved). Remaining before the first discovery: create the initial account in the UI, add the SNMP credential under Assets → Credentials, and a UniFi Allow policy for UDP 161 from 10.10.41.25 to the switch management addresses (10.10.10.2, 10.10.50.26) — VLAN 41 cannot reach them today (verified: ICMP/UDP blocked). **All done 2026-10-30 evening:** Brett created the account and the SNMP credential, added the UniFi policy ("Allow Scanopy SNMP to Switches"), and SNMP from scanopy-01 was verified answering on both switches (sysName Catalyst-2960X / Nexus-9372TX). The integrated daemon registered itself once the account existed and completed its first (light) discovery: 12 hosts, 0 warnings. The source of truth for rack U positions and power is [RACK-LAYOUT.md](RACK-LAYOUT.md). Scanopy will supply the observed network and service topology.

## Discovery results — first run (2026-10-30)

- First (light) discovery completed by the integrated daemon, which
  self-registered once the initial account existed: **12 hosts
  discovered, 0 warnings**.
- SNMP mapped the UCG-Fiber gateway at 10.10.41.1.
- Direct SNMP polls from scanopy-01 verified against both switches —
  Nexus 9372TX (10.10.50.26) and Catalyst 2960X (10.10.10.2) — over
  SNMPv2c read-only; LLDP is active on both.
- Deeper topology comparison against [PORT-MAP.md](../network/PORT-MAP.md)
  is still owed; treat the 12-host light result as a starting point,
  not a verified link map.

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

## As-built updates (2026-11-04)

- **Proxmox discovery phantom-IP bug.** Full scans rebind the
  pve01/pve02 host entities to stale UniFi client addresses on
  VLAN 50 — 10.10.50.139 (pve01) and 10.10.50.228 (pve02), each
  paired with the host's correct eno1 MAC; neither address exists
  on the hosts (each node has exactly one IPv4, 10.10.20.11/.12).
  The Proxmox API credential was consequently reported "never
  contacted": its target resolved to the phantom .228.
  Remediation applied in the database: the phantom IP rows were
  closed, 10.10.20.11/.12 restored, and the credential's host
  assignment pinned to the pve02 IP row (the UI-created assignment
  had `ip_address_ids` NULL, which is why it never fired). The
  durable fix is still owed: forget the two stale offline clients
  holding the R640 MACs in UniFi, or a future full scan can rebind
  the hosts again.
- **Docker Proxy credential.** A credential of type DockerProxy
  (port 2375 — the read-only WUD socket-proxy sidecars are
  unauthenticated, so there is no secret) is assigned to the six
  hosts exposing :2375: NPM (10.10.41.11), Paperless (.16),
  Scrutiny (.17), Observability (.20), Vault (.26), and Authentik
  (.28). docker-01 is deliberately excluded — it has no network
  Docker endpoint. The next discovery over those hosts should
  enumerate their containers.
- **SNMPv3 credential (in progress).** An SNMPv3 credential
  matching the LiveNX SNMP configuration (user `admin`, authPriv,
  SHA-1 authentication, AES-128 privacy; secrets live only in the
  credential store) is being created in the UI for the UCG-Fiber,
  the Nexus (10.10.50.26), and the Catalyst (10.10.10.2).
  Validation comes from the next discovery run's credential
  results; the existing v2c `public` credential stays assigned
  until v3 shows green per host.
- **LiveWire host repoint.** When LivePCA (VM 303) moved from DHCP
  10.10.41.129 to static 10.10.41.24, its Scanopy host entry was
  repointed to .24 and its blank name set to `livepca-01` (Manual);
  the Proxmox classification (VM 303, Qemu, Running) was untouched.

## References

- [Scanopy self-hosted install](https://scanopy.net/docs/self-hosted-server/server-installation/)
- [Scanopy L2 Physical view](https://scanopy.net/docs/using-scanopy/topology/l2-physical/)
- [Scanopy SNMP discovery](https://scanopy.net/docs/guides/integrations/snmp/)
- [Scanopy daemon deployment](https://scanopy.net/docs/setting-up-daemons/planning-daemon-deployment/)
