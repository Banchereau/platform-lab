variable "k8s_vms" {
  description = "Kubernetes virtual machines"

  type = map(object({
    vm_id     = number
    on_boot   = bool
    cores     = number
    memory    = number
    disk_size = number
    ip        = string
  }))
}
variable "k3s_version" {
  description = "Version K3s utilisée pour le cluster"
  type        = string
  default     = "v1.36.4+k3s1"
}
