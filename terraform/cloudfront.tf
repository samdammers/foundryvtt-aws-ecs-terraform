resource "aws_cloudfront_distribution" "foundry" {
  count = var.use_cloudfront ? 1 : 0

  enabled             = true
  is_ipv6_enabled     = true
  http_version        = "http2and3"
  aliases             = [local.foundry_fqdn]
  price_class         = "PriceClass_All"
  wait_for_deployment = true

  # Origin is the ECS task's current public IP, kept up to date via the
  # foundry-manager Lambda which fires on ECS Task State Change (RUNNING).
  origin {
    domain_name = local.origin_fqdn
    origin_id   = "foundry-ecs"

    custom_origin_config {
      http_port                = local.foundry_port
      https_port               = 443
      origin_protocol_policy   = "http-only"
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_read_timeout      = 60
      origin_keepalive_timeout = 60
    }
  }

  default_cache_behavior {
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "foundry-ecs"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    # CachingDisabled - Foundry is fully dynamic
    cache_policy_id = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    # AllViewer - forward all headers/cookies/QS, including Connection + Upgrade for WebSocket
    origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.foundry_cf[0].certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = local.tags
}
