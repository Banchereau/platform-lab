resource "random_password" "k3s_token" {
  length      = 32
  special     = false
  upper       = false
  numeric     = true
  min_lower   = 1
  min_numeric = 1
}
