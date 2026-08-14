# Proxmox VE + Backup Server automated installation

Reusable, PXE-free deployment kit for:

- 2 × Dell PowerEdge R640 running Proxmox VE
- 2 × Dell PowerEdge R440 running Proxmox VE
- 1 × Supermicro server running Proxmox Backup Server (PBS)

## Recommended design

Use **one common automated PVE ISO** for all four Dell servers and **one automated PBS ISO** for the Supermicro. Mount the same PVE ISO through each Dell iDRAC's Virtual Media and boot all four servers in parallel. The installer obtains a host-specific TOML answer from the included HTTP answer server, matched by Dell service tag first and management MAC second.

This is not PXE: each server boots an ISO through iDRAC or USB. HTTP is used only to retrieve its small answer file. Proxmox officially supports fetching an answer over HTTP(S), sends machine-identifying information in the POST, automatically selects the `Automated Installation` entry after ten seconds, and supports an ISO-integrated first-boot executable.[1]

### Why this is the easiest repeatable option

- One PVE image, not four per-host images.
- Four PVE installations can run simultaneously.
- No TFTP, DHCP options, PXE firmware, or boot-server maintenance.
- Rebuilds are inventory changes plus the same ISO and server.
- Secrets and generated ISOs stay outside Git.

## Critical safety warning

> **The automated installer erases the disks selected by each host's `disks` list.**
>
> Do not boot an automated ISO until you have verified, from iDRAC storage inventory or installer debug mode, that `sda`/`sdb` (or your chosen devices) are the intended OS disks. Dell PERC virtual disks may appear as one logical disk; ZFS must not be placed on top of a hardware RAID virtual disk. Choose either PERC-managed RAID with ext4/xfs, or HBA/JBOD disks with ZFS—not both.

The example inventory deliberately contains `CHANGE_ME` and documentation-only addresses. Validation refuses to serve it.

## Repository contents

```text
.github/workflows/test.yml          GitHub Actions tests
first-boot/pve-first-boot.sh        Safe PVE first-boot validation
first-boot/pbs-first-boot.sh        Safe PBS first-boot validation
post-deploy/create_cluster.sh       Guarded cluster creation helper
post-deploy/create_pbs_datastore.sh Guarded PBS datastore helper
scripts/build_isos.sh               Builds and inspects both automated ISOs
scripts/generate_tls_certificate.sh Creates pinned HTTPS certificate
scripts/run_answer_server.sh        Starts the host-aware answer service
scripts/validate_inventory.py       Fails closed on bad/placeholder inventory
server/answer_server.py             Dependency-free answer server
systemd/proxmox-answer-server.service Optional persistent Linux service
network/                             Nexus 9K VLAN/port templates
remote-access/                       Tailscale design, policy, installer
docs/PBS-STORAGE.md                  PBS disk/controller design checklist
inventory.example.json              Five-host sanitized template
secrets.env.example                 Secret/environment template
```

## Prerequisites

1. Download current official PVE and PBS ISO files. Do **not** commit ISO files to Git.
2. Use an x86-64 Debian/Proxmox build machine with:

   ```bash
   apt update
   apt install proxmox-auto-install-assistant xorriso whois
   ```

3. A temporary DHCP lease must be available on the installation network so the booted installer can reach the answer server. The installed host then uses the static address from the inventory.
4. The answer server's TCP port (default `8080`) must be reachable by all five servers.
5. Collect each server's:
   - service tag/system serial
   - MAC of the intended management NIC
   - final FQDN and CIDR
   - exact installer-visible OS disk names
   - storage-controller mode
6. For ZFS, expose disks directly via HBA/JBOD. PBS recommends redundant ZFS **or** hardware RAID with protected write cache and explicitly says ZFS is not compatible with a hardware RAID controller.[2]

## Network design (Nexus 9K)

Use separate VLANs for iDRAC/BMC, PVE/PBS management, PBS backup traffic, Corosync, and VM networks even though they share one Nexus. See `network/PORT-MAP.md` and `network/nexus9k.example.cfg`. Every sample interface has a descriptive label for fast operations. The Nexus template assumes an upstream firewall performs inter-VLAN routing and policy; do not paste it until interface numbers and existing configuration have been reviewed.

One Nexus is a single failure domain, and iDRAC on that same switch is only logically out-of-band. A second switch, dual links, and a separate switch-management path are sensible later improvements.

## Configure

```bash
cp inventory.example.json inventory.json
cp secrets.env.example .env
chmod 600 .env
```

Create a pinned TLS certificate using the answer server's installation-VLAN IP or DNS name:

```bash
scripts/generate_tls_certificate.sh 10.10.20.50 tls
```

Copy the printed certificate paths and SHA-256 fingerprint into `.env`. Use an `https://` `ANSWER_URL`; the build refuses plaintext HTTP.

Edit `inventory.json`. Replace every placeholder and documentation address. For a public repository, keep `inventory.json` untracked; it is ignored by default. If this repository is later made private and you intentionally want to store site inventory, remove that ignore entry—but never commit `.env`.

Generate a root password hash without storing the clear-text password:

```bash
mkpasswd -m sha-512
```

Paste the resulting hash into `.env` as `ROOT_PASSWORD_HASH`. Generate a high-entropy token with `printf 'installer:'; openssl rand -hex 24`, store it as `ANSWER_TOKEN`, and set `ANSWER_URL` to the answer server address reachable from the installation VLAN. Validation rejects the public placeholder, short secrets, and low-variety values.

Validate:

```bash
python3 scripts/validate_inventory.py inventory.json
python3 -m unittest discover -s tests -v
```

## Run the answer server

On a Mac/Linux workstation for a one-time deployment:

```bash
scripts/run_answer_server.sh --listen 0.0.0.0 --port 8080
curl --cacert tls/answer-server.crt https://10.10.20.50:8080/healthz
```

For a persistent Linux deployment, copy this repository to `/opt/proxmox-deploy-kit`, then install the supplied unit:

```bash
sudo scripts/install_answer_service.sh
curl --cacert tls/answer-server.crt https://10.10.20.50:8080/healthz
```

## Build the two reusable ISOs

Run on the build machine:

```bash
scripts/build_isos.sh \
  /path/to/proxmox-ve.iso \
  /path/to/proxmox-backup-server.iso
```

Outputs:

```text
output/proxmox-ve-auto.iso
output/proxmox-backup-server-auto.iso
output/SHA256SUMS
```

The build script runs Proxmox's ISO inspection command after each build. The authorization token is embedded in the ISOs in plain text by the Proxmox tooling, so protect generated ISOs and rotate the token after deployment.[1]

## Deploy

### Four Dell PVE nodes

1. Verify the answer service health endpoint.
2. In each iDRAC, mount `output/proxmox-ve-auto.iso` as Virtual Media.
3. Set a one-time boot from Virtual CD/DVD/ISO.
4. Start one server first and watch the answer-server log for the correct host match.
5. Verify it boots with its expected FQDN/IP and that `/root/proxmox-deployment/first-boot-complete` exists.
6. If correct, boot the remaining three in parallel.
7. Unmount Virtual Media when complete.

### Supermicro PBS

1. Mount `output/proxmox-backup-server-auto.iso` through IPMI virtual media or write it to USB.
2. Boot it and verify the answer server identifies `pbs01`.
3. After installation, prepare and mount the dedicated backup filesystem.
4. Create the PBS datastore only after verifying the mount:

   ```bash
   post-deploy/create_pbs_datastore.sh pbs-main /backup/pbs-main
   ```

Before choosing the final disk layout, review `docs/PBS-STORAGE.md`. The preferred design is mirrored OS SSDs plus a separate redundant datastore, using either direct-disk ZFS or ext4/XFS on protected hardware RAID—not ZFS layered over hardware RAID.[2][7]

PBS's official ISO installer can install to ext4, xfs, or ZFS and overwrites selected disks.[2]

## Post-deployment

### Create the PVE cluster

Ensure all nodes resolve each other's management FQDNs, time synchronization is healthy, and the management network is stable.

On the intended first node:

```bash
post-deploy/create_cluster.sh homelab
```

On each remaining node, one at a time:

```bash
pvecm add <management-IP-of-first-node>
```

Do not create VMs or local configuration on nodes before joining; cluster joining replaces the joining node's cluster configuration.

### Add PBS to PVE

In the PBS GUI:

1. Create a least-privilege backup user/API token.
2. Grant it the required datastore permissions.
3. Copy the PBS certificate fingerprint.

In the PVE GUI, add **Datacenter → Storage → Add → Proxmox Backup Server** using the PBS address, datastore, token identity/secret, and fingerprint. Keep the API token secret in a password manager or GitHub Actions secret, never in this repository.

## Secure remote management

Use a dedicated Tailscale subnet-router appliance to reach the iDRAC and PVE/PBS management VLANs without Internet-facing port forwards. Tailscale's subnet-router model supports devices that cannot run the client, and grants restrict identities, destination CIDRs, and ports.[3][4] The full comparison, sample policy, and installer are in `remote-access/README.md`.

Pangolin is useful as an identity-aware reverse proxy for selected web applications, but it is not the primary recommendation for this environment because appliance work also requires SSH, Redfish/IPMI, virtual-console traffic, and subnet reachability.[5]

## Expected time

| Activity | First build | Later rebuild |
|---|---:|---:|
| Collect service tags, MACs, disks, IP plan | 30–60 min | 10–20 min |
| Prepare build host and customize inventory | 45–90 min | 10–20 min |
| Build/inspect both ISOs | 10–25 min | 10–20 min |
| Mount virtual media and verify first node | 20–35 min | 15–25 min |
| Install remaining PVE nodes in parallel | 20–40 min | 20–40 min |
| Install PBS and create datastore | 30–60 min | 25–45 min |
| Create cluster and connect PBS | 30–60 min | 20–40 min |
| Review/apply Nexus VLANs and port descriptions | 30–90 min | 15–30 min |
| Deploy/test Tailscale management access | 30–60 min | 15–30 min |
| **Total hands-on/elapsed estimate** | **about 4–7 hours** | **about 2–4 hours** |

Actual installation time depends mainly on iDRAC virtual-media speed, storage initialization, firmware, and network throughput. Installing the four PVE nodes in parallel avoids roughly three additional interactive install cycles.

## GitHub and licensing

The original scripts and documentation in this repository are licensed under the **MIT License**. This license is simple, permissive, and appropriate for a reusable infrastructure-automation repository. It does not license or redistribute Proxmox or Dell software, trademarks, firmware, or ISO images. Download vendor ISOs separately and accept their applicable terms.

This repository is public. Do not commit:

- `.env`, passwords, password hashes, or API tokens
- generated ISOs
- private SSH keys
- real inventory unless you deliberately accept publishing serials, MACs, hostnames, and network addresses

## Sources

[1] https://pve.proxmox.com/wiki/Automated_Installation — Proxmox VE Automated Installation
[2] https://pbs.proxmox.com/docs/installation.html — Proxmox Backup Server Installation
[3] https://tailscale.com/kb/1019/subnets — Tailscale subnet routers
[4] https://tailscale.com/kb/1337/acl-syntax — Tailscale access controls
[5] https://docs.pangolin.net/about/how-pangolin-works — Pangolin architecture
[7] https://pbs.proxmox.com/docs/sysadmin.html — Proxmox Backup Server Host Administration
