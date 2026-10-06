# SSH Hardening + FIDO2 Runbook — pve01, pve02, pve03, pbs01

FIDO2 upgrade path for the SSH baseline in `docs/SECURITY.md` (key-only auth,
fail2ban). Read that first; this runbook is the step-by-step implementation.

Goal: kill password-based SSH attacks on all four nodes and move admin logins to
touch-verified FIDO2 keys on the two YubiKey 5C NFCs (primary + backup). No
central auth server, no new moving parts.

What changes:
- SSH logins require a FIDO2 key (touch). Passwords stop working entirely.
- Root stays usable over SSH, but keys-only (`prohibit-password`). PVE needs
  root for CLI admin; this keeps it working while killing password guessing.
- SSH restricted to the tailnet; fail2ban as a backstop.

## Prerequisites

- Both YubiKey 5C NFCs in hand, FIDO2 PIN set (YubiKey Manager → FIDO2 →
  set PIN, or `ykman fido access change-pin`).
- A workstation with OpenSSH 8.2+ and the YubiKey plugged in (USB-C).
- Tailscale up on all four nodes; confirm with `tailscale status` on each.
- Current working SSH access to all four nodes (you'll keep one session open
  per node while you harden it — see the safety rule in Phase 3).

## Phase 1 — Generate resident FIDO2 keys (workstation)

Do this once per YubiKey. Touch the key when prompted.

```bash
ssh-keygen -t ed25519-sk -O resident -O verify-required \
  -C "brett-yubikey-primary" -f ~/.ssh/id_ed25519_sk_primary

ssh-keygen -t ed25519-sk -O resident -O verify-required \
  -C "brett-yubikey-backup" -f ~/.ssh/id_ed25519_sk_backup
```

- `-O resident`: the private key lives on the YubiKey. On a new machine,
  plug the key in and run `ssh-keygen -K` to pull it down.
- `-O verify-required`: every use needs the touch (plus PIN where applicable).
- Keep both `.pub` files; you'll never need to copy the private halves.

## Phase 2 — Distribute both public keys to all four nodes

Passwords still work at this point, so `ssh-copy-id` is fine. Use IPs if the
hostnames don't resolve on your LAN.

```bash
for h in pve01 pve02 pve03 pbs01; do
  ssh-copy-id -i ~/.ssh/id_ed25519_sk_primary.pub root@$h
  ssh-copy-id -i ~/.ssh/id_ed25519_sk_backup.pub  root@$h
done
```

Then verify: open a **second** session to each node and confirm the key login
works (you'll get a touch prompt). Do not proceed until all four accept the
FIDO2 keys.

## Phase 3 — Deploy the sshd hardening fragment

**Safety rule: keep your original session open on each node.** Apply the
change, then prove a *new* login works before closing the old session. If a
new login fails, your open session is your way back in.

On each node, create `/etc/ssh/sshd_config.d/90-hardening.conf`:

```
# SSH hardening — FIDO2 keys only, no passwords. 2026-10-06.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 60
```

Debian reads `sshd_config.d/*.conf` first, so this overrides the stock file
without editing it — cleaner across upgrades. Then:

```bash
sshd -t && systemctl restart sshd
```

`sshd -t` must print nothing (silence = valid). If it errors, fix the file and
re-run before restarting. After restart, open a **fresh** session to the node
and confirm the FIDO2 login works. Only then close the original session.

Notes:
- PVE cluster inter-node SSH already uses root keypairs and is unaffected
  (`PubkeyAuthentication` stays on).
- Leave any pre-existing non-FIDO2 keys in `authorized_keys` until the FIDO2
  flow is proven on all four nodes. Remove them after, as cleanup.

## Phase 4 — Restrict SSH to the tailnet

SSH should not be reachable from the LAN at all.

- **pve01–pve03:** Datacenter → Firewall → add a rule on each node (or the
  datacenter level): accept TCP/22 from `100.64.0.0/10`, drop everything else.
  This fits the firewall-as-code setup already in the repo.
- **pbs01** (no PVE firewall): a single nftables rule, e.g.

```bash
nft add rule inet filter input tcp dport 22 ip saddr != 100.64.0.0/10 drop
```

  and persist it in your nftables config. (ufw equivalent:
  `ufw allow from 100.64.0.0/10 to any port 22 && ufw deny 22/tcp` —
  order matters, allow first.)

Verify from a non-tailnet address that port 22 no longer answers.

## Phase 5 — fail2ban (backstop)

```bash
apt install -y fail2ban
systemctl enable --now fail2ban
fail2ban-client status sshd
```

The stock `sshd` jail is enough. It now guards a keys-only service, so it
should stay quiet — that's the point.

## Phase 6 — Verification checklist

- [ ] Fresh FIDO2 login works on pve01, pve02, pve03, pbs01 (touch prompt).
- [ ] `ssh -o PreferredAuthentications=password root@<node>` fails on all four.
- [ ] Port 22 unreachable off-tailnet.
- [ ] `fail2ban-client status sshd` shows the jail active.
- [ ] Old non-FIDO2 keys removed from `/root/.ssh/authorized_keys` (cleanup).
- [ ] `ssh-keygen -K` tested with each YubiKey on a second machine (proves the
      resident keys are actually recoverable).

## Rollback

If anything goes wrong and you're locked out of new sessions (old session
still open): `rm /etc/ssh/sshd_config.d/90-hardening.conf &&
systemctl restart sshd` — passwords work again immediately.

If you've already closed everything and are fully locked out: iDRAC virtual
console (Dells) or IPMI KVM (Supermicro) → local root login → same removal.

## Revisit later

- When the second YubiKey arrives, it is the backup in this scheme — generate
  its key in Phase 1 and include it in Phase 2 before it goes in the drawer.
- If a key is lost: remove its `.pub` line from all four nodes'
  `authorized_keys`, generate a replacement on the spare.
