# ---------------------------------------------------------------------------
# Connection
# ---------------------------------------------------------------------------

variable "proxmox_endpoint" {
  description = "Proxmox API endpoint, e.g. https://pve01.mgmt.example.com:8006/"
  type        = string
}

variable "proxmox_api_token" {
  description = "Proxmox API token (user@realm!token-name=secret). Marked sensitive; prefer the PROXMOX_VE_API_TOKEN env var."
  type        = string
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Skip TLS verification (self-signed PVE certs). Set false once you install proper certs."
  type        = bool
  default     = true
}

variable "proxmox_ssh_username" {
  description = "SSH user for provider operations that need it (key must be in ssh-agent)."
  type        = string
  default     = "root"
}

# ---------------------------------------------------------------------------
# Shared infrastructure settings
# ---------------------------------------------------------------------------

variable "lxc_template" {
  description = "LXC template volume ID. Must exist on every node (Datacenter -> node -> local -> CT Templates). Adjust the filename to what you actually downloaded."
  type        = string
  default     = "local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst"
}

variable "container_storage" {
  description = "Storage for LXC root disks."
  type        = string
  default     = "local-lvm"
}

variable "vm_storage" {
  description = "Storage for VM disks."
  type        = string
  default     = "local-lvm"
}

variable "infra_bridge" {
  description = "Linux bridge carrying the infra VLAN."
  type        = string
  default     = "vmbr0"
}

variable "infra_vlan" {
  description = "VLAN ID for infrastructure services (see network/PORT-MAP.md)."
  type        = number
  default     = 41
}

variable "infra_gateway" {
  description = "Default gateway for the infra VLAN."
  type        = string
  default     = "10.10.41.1"
}

variable "dns_servers" {
  description = "Upstream DNS until AdGuard is live; afterwards point everything at the AdGuard IP."
  type        = list(string)
  default     = ["1.1.1.1", "1.0.0.1"]
}

variable "ssh_public_key" {
  description = "Admin SSH public key injected into every container/VM."
  type        = string
}

variable "ubuntu_template_vmid" {
  description = "VMID of the Ubuntu cloud-init template built by templates/cloud-init/create-ubuntu-cloudinit-template.sh."
  type        = number
  default     = 9000
}

variable "vm_admin_user" {
  description = "Default cloud-init user on the Ubuntu template."
  type        = string
  default     = "ubuntu"
}

# ---------------------------------------------------------------------------
# Workload definitions
# ---------------------------------------------------------------------------

variable "containers" {
  description = "LXC fleet. Placement is spread across nodes so one host failure cannot take out the whole management plane."
  type = map(object({
    node          = string
    vmid          = number
    hostname      = string
    ipv4          = string # CIDR, e.g. "10.10.41.10/24"
    cores         = number
    memory_mb     = number
    disk_gb       = number
    description   = string
    startup_order = number
  }))

  default = {
    adguard = {
      node          = "pve01"
      vmid          = 200
      hostname      = "adguard"
      ipv4          = "10.10.41.10/24"
      cores         = 1
      memory_mb     = 512
      disk_gb       = 4
      description   = "AdGuard Home - internal DNS and ad blocking"
      startup_order = 1
    }
    proxy = {
      node          = "pve02"
      vmid          = 201
      hostname      = "proxy"
      ipv4          = "10.10.41.11/24"
      cores         = 1
      memory_mb     = 512
      disk_gb       = 4
      description   = "Nginx Proxy Manager - TLS termination for internal web UIs"
      startup_order = 2
    }
    uptime = {
      node          = "pve03"
      vmid          = 202
      hostname      = "uptime"
      ipv4          = "10.10.41.12/24"
      cores         = 1
      memory_mb     = 512
      disk_gb       = 4
      description   = "Uptime Kuma - service monitoring and push alerts"
      startup_order = 3
    }
    semaphore = {
      node          = "pve02"
      vmid          = 203
      hostname      = "semaphore"
      ipv4          = "10.10.41.13/24"
      cores         = 1
      memory_mb     = 1024
      disk_gb       = 8
      description   = "Semaphore - Ansible automation UI"
      startup_order = 3
    }
    ntfy = {
      node          = "pve01"
      vmid          = 204
      hostname      = "ntfy"
      ipv4          = "10.10.41.14/24"
      cores         = 1
      memory_mb     = 512
      disk_gb       = 4
      description   = "ntfy - self-hosted push notifications for alerts"
      startup_order = 3
    }
  }
}

variable "vms" {
  description = "VMs cloned from the Ubuntu cloud-init template (full clones for isolation)."
  type = map(object({
    node          = string
    vmid          = number
    hostname      = string
    ipv4          = string
    cores         = number
    memory_mb     = number
    disk_gb       = number
    description   = string
    startup_order = number
  }))

  default = {
    observability = {
      node          = "pve02"
      vmid          = 300
      hostname      = "observability"
      ipv4          = "10.10.41.20/24"
      cores         = 4
      memory_mb     = 8192
      disk_gb       = 60
      description   = "Grafana + Prometheus + Loki (prometheus-pve-exporter for cluster metrics)"
      startup_order = 4
    }
    docker = {
      node          = "pve03"
      vmid          = 301
      hostname      = "docker-01"
      ipv4          = "10.10.41.21/24"
      cores         = 4
      memory_mb     = 8192
      disk_gb       = 60
      description   = "Docker workload host (VM, not LXC - avoids nesting issues)"
      startup_order = 4
    }
  }
}
