terraform {
  required_version = "~> 1.15"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.111.1"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}

provider "proxmox" {
  insecure = true

  ssh {
    agent    = true
    username = "terraform"
  }
}
