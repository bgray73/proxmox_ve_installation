# Node security baseline

> **Fleet CVE watch (as-built 2026-11-01):** a daily watch
> cross-checks new CISA KEV entries against the fleet inventory and
> reports only CVEs that plausibly apply to a fleet device, verifying
> live patch state on a match. Current state: **CVE-2026-98432 is
> fixed** in the running kernel (7.0.14-26-pve) on both PVE nodes and
> pdm01. MPTCP is disabled on both nodes
> (`/etc/sysctl.d/99-disable-mptcp.conf`) as a partial mitigation
> only — the kernel fix is what closes the CVE. Fragnesia
> (CVE-2026-46300) is fixed in all running kernels, and there is no
> PHP anywhere in the fleet (the PHP2Shell CVEs do not apply). The
> Ubuntu guests still await Ubuntu's own fixed kernel for
> CVE-2026-98432 and are not inbound-exposed.

Five controls, in this order, on all four nodes (`pve01`–`pve03`, `pbs01`).
Do them in one sitting per node so nothing is left half-applied. TOTP is
cluster-wide for PVE — enroll once, it covers all three nodes.

> Order matters: set a strong root password and enroll TOTP **before**
> touching SSH. If you lock yourself out of SSH, the web UI (with TOTP) is
> your way back in.

## 1. TOTP two-factor on the web UIs

PVE: **Datacenter → Access → Two Factor → Add → TOTP**, user `root@pam`.
Scan the QR with your authenticator app, confirm with a code, and save the
**recovery keys to the password manager** — they are the only way back in
if the authenticator is lost.

- TFA settings are cluster-wide (stored in `/etc/pve/priv/tfa.cfg`, synced
  by pmxcfs). One enrollment covers `pve01`–`pve03`.
- Repeat the same enrollment in the PBS web UI (**Configuration → Access
  Control**) for `root@pam` on `pbs01`.
- 8 failed TOTP attempts disables that factor; a recovery key re-enables
  it. If TOTP was the only factor, another admin (or root shell via iDRAC)
  must unlock it: `pveum user tfa unlock root@pam`.
- Break-glass rule: **no TOTP-less admin account** — it defeats the point.
  The recovery keys in the password manager *are* the break-glass. Add
  them to the offline-essentials checklist in `docs/DISASTER-RECOVERY.md`.
- Note for later: adding a node to the cluster via GUI fails with TFA on
  root; use the CLI join with `--ssh` at pairing time instead.

## 2. SSH: key-only auth

`PermitRootLogin prohibit-password` — **not** `no`. Justification: Proxmox
cluster operations (migration, replication, inter-node `pvesh`) SSH as
root with keys; `no` breaks them and removes your only admin SSH path.
`prohibit-password` keeps key-based root SSH working while killing
password auth.

On each node, as root:

```bash
# 1. Install your key FIRST (repeat for every node + pbs01)
mkdir -p ~/.ssh && chmod 700 ~/.ssh
cat >> ~/.ssh/authorized_keys <<'EOF'
ssh-ed25519 AAAA... your-key-here
EOF
chmod 600 ~/.ssh/authorized_keys

# 2. Open a SECOND session and confirm key login works before continuing.
#    Do not proceed until it does.

# 3. Then disable password auth:
cat > /etc/ssh/sshd_config.d/10-hardening.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
systemctl reload sshd
```

Verify the effective config (catches typos and conflicting stanzas):

```bash
sshd -T | grep -Ei '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin)'
# expect: no / no / prohibit-password
```

And prove password auth is really dead, from another machine:

```bash
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no root@<node>
# expect: Permission denied (publickey)
```

## 3. Unattended security updates (Debian only, never Proxmox)

```bash
apt install -y unattended-upgrades
```

Write `/etc/apt/apt.conf.d/52unattended-upgrades-security-only` (the `52`
prefix and `#clear` override the stock `50unattended-upgrades` list, which
we do not edit):

```
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=${distro_codename},label=Debian-Security";
        "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::MailReport "only-on-error";
```

Enable the daily run in `/etc/apt/apt.conf.d/20auto-upgrades`:

```
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
```

**Proxmox caveat:** this deliberately matches only the Debian security
origin — nothing from the Proxmox repos (`pve-no-subscription`,
`enterprise`). Auto-upgrading `pve-manager`, the PVE kernel, or PBS
mid-quorum is how you learn about fencing the hard way. Those updates
happen in the `docs/UPDATES.md` maintenance window, one node at a time.

Dry-run before trusting it:

```bash
unattended-upgrade --debug --dry-run   # logs to /var/log/unattended-upgrades/
```

## 4. fail2ban on SSH (defense in depth)

With Tailscale and the datacenter firewall restricting SSH to admin
networks, this is a backstop, not the plan. Keep it short:

```bash
apt install -y fail2ban
cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 <your-admin-ip-or-cidr>
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
EOF
systemctl enable --now fail2ban
```

Put your own admin IP in `ignoreip` **before** enabling — your own typo
during step 2 must not ban you. Never edit `jail.conf` (package updates
overwrite it); `jail.local` wins.

## 5. Verify everything

| Control | Check | Expected |
|---|---|---|
| TOTP | Log in via a private window | Password prompt, then TOTP prompt |
| TOTP enrolled | Datacenter → Access → Two Factor | Entry for `root@pam` |
| SSH keys | `sshd -T \| grep -Ei '^(passwordauthentication\|permitrootlogin)'` | `no` / `prohibit-password` |
| SSH passwords dead | `ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no root@<node>` | `Permission denied (publickey)` |
| Unattended upgrades | `apt-config dump \| grep -A4 'Origins-Pattern'` | Only the two `Debian-Security` lines |
| Unattended dry-run | `unattended-upgrade --debug --dry-run` | Completes, no Proxmox packages selected |
| fail2ban | `fail2ban-client status sshd` | Jail active, 0 banned (so far) |

Run the table once per node. When every row is green, the baseline is done.

## TLS and SSO state (as-built 2026-11-03)

- A local CA ("Homelab CA") lives on the Lenovo (`~/homelab-ca`, root
  valid to 2036-10-27). Leaf lifetime is ~825 days; the current fleet
  leaves all expire **2029-02-05**, so they come due together.
- NPM (CT 201) serves one custom certificate for all its proxy hosts —
  currently **v8, 20 explicit SANs** (v6 added `paperless.homelab`,
  v7 added `scrutiny.homelab`, v8 added `wud.homelab`, all 2026-11-03). A `*.homelab`
  wildcard does NOT validate for two-label names, so every served
  name must be listed explicitly. Swap in place at
  `/opt/npm/data/custom_ssl/npm-1/` (new key + CSR signed by the CA;
  replace `fullchain.pem` and `privkey.pem`, keep the previous pair
  as `.bak-v<n>`) and restart the NPM container.
- **iDRACs** serve CA certificates for `idrac-pve01.homelab` /
  `idrac-pve02.homelab`, installed via the on-box CSR flow — the only
  reliable path on iDRAC9 FW 7.x: iDRAC Settings -> Services -> Web
  Server -> SSL/TLS Certificate Signing Request, Step 2 "Upload Signed
  Certificate". Externally generated key/certs fail Redfish
  ReplaceCertificate validation (RAC0160), and `sslcertupload` is not
  supported over iDRAC SSH. CSR attributes need OU and email or
  generation fails (RAC1176); the SAN attribute format is plain
  `name,ip`; the boxes' `CsrEmailAddr` is brett_gray@me.com. AdGuard
  rewrites point the iDRAC names **directly** at the iDRACs, not via
  NPM — the out-of-band path stays independent of the VM fleet.
- **LiveNX and LivePCA** serve in-app CA certificates (DNS + IP SANs)
  installed through LiveAdmin; `livenx.homelab` / `livepca.homelab`
  resolve directly to the apps. Both serve their user UI on 443;
  8443 is the LiveAdmin interface.
- Client trust is per browser family: Firefox uses its own store;
  Chromium browsers use the Windows Trusted Root store. Import
  `homelab-ca.crt` once per machine/browser family.
- **SSO (Authentik, VM 309).** LiveNX SAML was renamed from the IP to
  `livenx.homelab` on 2026-11-03 — the SP fields (Entity ID, Host
  Name, Consumer Login/Logout URLs) and the provider's `acs_url` /
  `audience` must change together, or logins fail with an
  ACS-mismatch error. Local `admin` remains break-glass on both apps.
  LivePCA (LiveWire) SAML was built the same day (provider `livepca`;
  a `LiveWire_Roles` property mapping emits `Administrator` for
  akadmin/bgray/Admins; LiveWire's ACL Administrator role lists
  admin, akadmin, bgray); SSO login verified working by Brett on
  2026-11-03 after the `name_id_mapping` fix below.
  Runbook lesson: a newly created SAML provider must copy
  `name_id_mapping` (the Username mapping) — the default sends an
  opaque ID that SPs matching users by name reject (LiveWire
  answered its ACS with 401 until this was set).
- **TACACS+ (server built 2026-11-03, switch wiring pending).** CT 205
  `tacacs-01` (10.10.41.15) — the fleet's only Ubuntu 24.04 container,
  because Debian 13 and current Ubuntu both dropped the `tacacs+`
  package; it runs tac_plus F4.0.4.32 built from the shrubbery source
  under a systemd unit. `/etc/tac_plus.conf` (mode 600) holds
  per-switch host keys (Nexus 10.10.50.26, Catalyst 10.10.10.2), a
  `netadmin` group (exec priv-lvl 15, `shell:roles="network-admin"`),
  and the sole user `bgray`; the keys and password live only in the
  container's `/root/tacacs-secrets.txt`. Switch AAA is NOT yet
  pointed at it — that waits on UniFi allows for TCP 49 from the two
  switch networks, then AAA config with local fallback, tested in a
  second session before the first closes.
- **Also deployed 2026-11-03:** Paperless-ngx (CT 206, 10.10.41.16,
  Docker compose with PostgreSQL 16 + Redis; native-login tier like
  Vaultwarden), What's Up Docker on docker-01 (VM 301; image-update
  monitoring for every fleet Docker host via read-only socket-proxy
  sidecars, native ntfy trigger — delivery waits on a VLAN 41 →
  192.168.1.190:2586 UniFi allow; Diun was deployed first and swapped
  out for WUD the same evening at the owner's pick), and Scrutiny
  (hub CT 207, 10.10.41.17, image pinned to
  `v0.10.0-omnibus` — the `master-omnibus` tag is a stale dev-0.8.2
  build that breaks collector association; collectors on both PVE
  hosts read the physical SSDs via PERC megaraid passthrough on a
  15-minute systemd timer). NPM proxy hosts for `paperless.homelab`,
  `scrutiny.homelab`, and `wud.homelab` are still to be added (cert v8,
  AdGuard rewrites, and Homepage tiles are already in place; Scrutiny gets an
  Authentik proxy gate, as it has no native auth).
