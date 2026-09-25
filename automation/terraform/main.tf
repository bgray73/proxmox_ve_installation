# Provider connection. Prefer environment variables over committed files:
#
#   export PROXMOX_VE_ENDPOINT="https://pve01.mgmt.example.com:8006/"
#   export PROXMOX_VE_API_TOKEN='terraform@pve!provider=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
#
# Create a dedicated least-privilege API token (Datastore.Allocate, VM.Allocate,
# VM.Clone, VM.Config.*, VM.Audit, Sys.Audit on the relevant paths) rather than
# using root. Some provider operations need SSH too, so keep an SSH key in your
# agent that is authorized on every PVE node.
provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_insecure

  ssh {
    agent    = true
    username = var.proxmox_ssh_username
  }
}
