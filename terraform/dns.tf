resource "aws_route53_record" "foundry" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = local.foundry_fqdn
  type    = "A"

  alias {
    name                   = aws_lb.foundry.dns_name
    zone_id                = aws_lb.foundry.zone_id
    evaluate_target_health = true
  }
}
