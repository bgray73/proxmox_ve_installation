# Cloud-init VM templates (optional)

Build a cloneable **cloud-init** golden template on Proxmox VE from an official distro cloud image.

**Not part of** the automated PVE/PBS ISO install path. Run this only after nodes are up.

## Prerequisites

- Root shell on a Proxmox VE node
- Storage for VM disks (e.g. `local-lvm`, `local-zfs`)
- Optional: storage with **Snippets** enabled for custom `vendor`/`user` YAML
- Outbound HTTPS to download the cloud image

## Quick start (Ubuntu 24.04)

```bash
# On a PVE node, from a clone of this repo:
cd templates/cloud-init
sudo ./create-ubuntu-cloudinit-template.sh

# Or override defaults:
sudo VMID=9000 STORAGE=local-lvm BRIDGE=vmbr0 \
  SSH_KEYS_FILE=/root/.ssh/authorized_keys \
  ./create-ubuntu-cloudinit-template.sh
```

The script:

1. Downloads the Ubuntu Noble server cloud image
2. Creates a VM, imports the disk, attaches a cloud-init drive
3. Sets default `ciuser` / SSH keys / DHCP
4. Optionally attaches `snippets/vendor.yaml` if present on snippet storage
5. Converts the VM to a template (`qm template`)

## Clone a VM from the template

```bash
qm clone 9000 120 --name web-01 --full
qm set 120 --ipconfig0 ip=10.0.1.120/24,gw=10.0.1.1
qm set 120 --nameserver 10.0.1.1 --searchdomain lab.home
qm start 120
```

Override user/keys per clone if needed:

```bash
qm set 120 --ciuser ubuntu --sshkeys /root/.ssh/authorized_keys
```

## Custom vendor snippet

1. Datacenter → Storage → (e.g. `local`) → Edit → enable **Snippets**.
2. Copy the example:

   ```bash
   mkdir -p /var/lib/vz/snippets
   cp snippets/vendor.yaml.example /var/lib/vz/snippets/vendor.yaml
   # edit packages / runcmd as needed
   ```

3. Re-run template creation, or on an existing template VM (before `qm template`):

   ```bash
   qm set 9000 --cicustom "vendor=local:snippets/vendor.yaml"
   ```

Set **all** `cicustom` pieces in one `qm set` command; a later `--cicustom` replaces the previous value entirely.

## Manual equivalent (reference)

```bash
VMID=9000
STORAGE=local-lvm
wget -O /tmp/noble-server-cloudimg-amd64.img \
  https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
qm create $VMID --name ubuntu-2404-cloudinit-template --ostype l26 \
  --memory 2048 --cores 2 --cpu host \
  --net0 virtio,bridge=vmbr0 --agent enabled=1 \
  --serial0 socket --vga serial0
qm importdisk $VMID /tmp/noble-server-cloudimg-amd64.img $STORAGE
# Attach imported volume (check qm config $VMID for exact disk name)
qm set $VMID --scsihw virtio-scsi-single --scsi0 ${STORAGE}:vm-${VMID}-disk-0,discard=on
qm set $VMID --boot order=scsi0
qm set $VMID --ide2 ${STORAGE}:cloudinit
qm set $VMID --ciuser ubuntu --sshkeys ~/.ssh/authorized_keys --ipconfig0 ip=dhcp
qm template $VMID
```

## Ansible (next step)

After the template exists, provision clones with `community.proxmox.proxmox_kvm` (`clone`, `ciuser`, `ipconfig`, `sshkeys`, `state: started`), then configure the guest over SSH.

## Safety

- Prefer SSH keys over `--cipassword` on templates.
- Use high VMID range (9000+) for templates.
- Full clones (`--full`) are safer for independent VMs; linked clones share base disks.
- Do not commit real SSH private keys or production passwords into this repository.
