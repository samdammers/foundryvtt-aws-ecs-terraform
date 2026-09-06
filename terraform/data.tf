data "aws_route53_zone" "main" {
  zone_id = var.hosted_zone_id
}

data "aws_route_tables" "default_vpc" {
  vpc_id = var.vpc_id
}

data "aws_ec2_managed_prefix_list" "cloudfront" {
  count = var.use_cloudfront ? 1 : 0
  name  = "com.amazonaws.global.cloudfront.origin-facing"
}
