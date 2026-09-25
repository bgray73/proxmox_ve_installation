# Node security baseline

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
