terraform {
  # Works with Terraform >= 1.6 and OpenTofu >= 1.6.
  required_version = ">= 1.6.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.80"
    }
  }
}
