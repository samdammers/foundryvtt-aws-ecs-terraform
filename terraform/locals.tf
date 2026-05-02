locals {
  name_prefix = "foundry"
  region      = "ap-southeast-4"

  foundry_fqdn = "foundry.${var.domain}"
  api_fqdn         = "api.foundry.${var.domain}"
  foundry_port     = 30000

  tags = {
    Service = "foundry"
  }
}
