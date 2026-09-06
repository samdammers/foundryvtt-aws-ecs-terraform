locals {
  region = var.aws_region

  foundry_fqdn = "foundry.${var.domain}"
  origin_fqdn  = "origin.foundry.${var.domain}" # only used when use_cloudfront = true
  api_fqdn     = "api.foundry.${var.domain}"
  foundry_port = 30000

  tags = {
    Service = "foundry"
  }
}
