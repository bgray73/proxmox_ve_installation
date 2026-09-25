# Ansible — day-2 operations

Playbooks for hardening and updating the cluster nodes. Inventory is
generated from the deploy-kit's `inventory.json` so host data stays in one
place.

## Setup

```bash
# from this directory
python3 scripts/gen_inventory.py > inventory.json
ansible-playbook -i inventory.json playbooks/harden.yml
```

`inventory.json` is git-ignored (it contains internal IPs). Regenerate it
whenever the deploy-kit inventory changes.

`ansible.cfg` assumes SSH as root with `~/.ssh/id_ed25519`. Adjust
`remote_user` / `private_key_file` if yours differs.

## Playbooks

- `playbooks/harden.yml` — run once after first boot, before clustering:
  timezone, NTP (systemd-timesyncd), admin SSH keys for root, sshd
  hardening (key-only root login), fail2ban. **Fails closed** if you haven't
  defined `admin_ssh_keys` — edit the vars at the top of the playbook first,
  and verify `ssh root@<node>` works with your key before running.
- `playbooks/rolling-update.yml` — updates the whole cluster one node at a
  time: quorum gate before each node, `dist-upgrade`, reboot only when
  required, quorum gate after. Migrate or HA-manage guests first — the
  playbook reminds you but does not move them.
- `playbooks/packet-capture.yml` — on-demand packet capture on any node.
  Spins up an ephemeral, privileged `netshoot` container on the **host**
  network namespace (a regular LXC can't see host interfaces), runs tcpdump,
  then stops and fetches the pcap for Wireshark:

  ```bash
  # start (capture the Proxmox web UI traffic on pve01)
  ansible-playbook -i inventory.json playbooks/packet-capture.yml -l pve01 \
    -e "capture_state=started capture_interface=vmbr0 capture_filter='tcp port 8006' capture_name=gui-debug"

  # stop + pull the pcap into ./captures/pve01/
  ansible-playbook -i inventory.json playbooks/packet-capture.yml -l pve01 \
    -e "capture_state=stopped capture_name=gui-debug"
  ```

  Useful interfaces: `vmbr0` (all tagged traffic), `vmbr0.20` (one VLAN),
  `eno1` (physical NIC). Installs `docker.io` on the node on first use;
  the container is `--rm` ephemeral. Treat captures as sensitive and keep
  the windows short.

Only `ansible.builtin` modules are used, so no Galaxy collections to
install.
