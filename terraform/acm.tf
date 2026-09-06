# ALB certificate - active only when use_cloudfront = false.
resource "aws_acm_certificate" "foundry_alb" {
  count = var.use_cloudfront ? 0 : 1

  domain_name       = local.foundry_fqdn
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = local.tags
}

resource "aws_route53_record" "cert_validation_alb" {
  for_each = var.use_cloudfront ? {} : {
    for dvo in aws_acm_certificate.foundry_alb[0].domain_validation_options :
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
  count = var.use_cloudfront ? 0 : 1

  certificate_arn         = aws_acm_certificate.foundry_alb[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation_alb : r.fqdn]
}

# CloudFront certificate - active only when use_cloudfront = true. CloudFront
# requires ACM certificates in us-east-1 regardless of deployment region.
resource "aws_acm_certificate" "foundry_cf" {
  count = var.use_cloudfront ? 1 : 0

  provider          = aws.us_east_1
  domain_name       = local.foundry_fqdn
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = local.tags
}

resource "aws_route53_record" "cert_validation_cf" {
  for_each = var.use_cloudfront ? {
    for dvo in aws_acm_certificate.foundry_cf[0].domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  } : {}

  zone_id         = data.aws_route53_zone.main.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "foundry_cf" {
  count = var.use_cloudfront ? 1 : 0

  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.foundry_cf[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation_cf : r.fqdn]
}
