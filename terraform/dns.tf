resource "aws_route53_record" "foundry_alb" {
  count = var.use_cloudfront ? 0 : 1

  zone_id = data.aws_route53_zone.main.zone_id
  name    = local.foundry_fqdn
  type    = "A"

  alias {
    name                   = aws_lb.foundry[0].dns_name
    zone_id                = aws_lb.foundry[0].zone_id
    evaluate_target_health = true
  }
}

# CloudFront alias - Z2FDTNDATAQYW2 is the global hosted zone ID for all CloudFront distributions
resource "aws_route53_record" "foundry_cf" {
  count = var.use_cloudfront ? 1 : 0

  zone_id = data.aws_route53_zone.main.zone_id
  name    = local.foundry_fqdn
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.foundry[0].domain_name
    zone_id                = "Z2FDTNDATAQYW2"
    evaluate_target_health = false
  }
}

# Dynamic origin record - the foundry-manager Lambda updates this with the ECS task's
# current public IP when the task reaches RUNNING state. The placeholder keeps the
# record valid in Terraform state; CloudFront simply can't reach the origin until
# the ECS task is running and Lambda has updated this.
resource "aws_route53_record" "foundry_origin" {
  count = var.use_cloudfront ? 1 : 0

  zone_id = data.aws_route53_zone.main.zone_id
  name    = local.origin_fqdn
  type    = "A"
  ttl     = 60
  records = ["192.0.2.1"] # RFC 5737 TEST-NET placeholder, Lambda overwrites on task start

  lifecycle {
    ignore_changes = [records] # Lambda owns this value at runtime
  }
}
