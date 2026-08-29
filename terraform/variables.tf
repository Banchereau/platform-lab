variable "k8s_vms" {
  description = "Kubernetes virtual machines"

  type = map(object({
    vm_id     = number
    on_boot   = bool
    cores     = number
    memory    = number
    disk_size = number
  }))
}

variable "k3s_token" {
  description = "Token utilisé par K3s pour joindre les agents au serveur"
  type        = string
  sensitive   = true
}
