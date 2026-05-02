# New ALB certificate covering both the testing subdomain and the production subdomain.
# Using a single cert for both means no cert swap is needed at cutover time.
resource "aws_acm_certificate" "foundry_alb" {
  domain_name       = local.foundry_fqdn
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = local.tags
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.foundry_alb.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id         = data.aws_route53_zone.main.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "foundry_alb" {
  certificate_arn         = aws_acm_certificate.foundry_alb.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}
