data "aws_caller_identity" "current" {}

data "aws_vpc" "default" {
  id = var.vpc_id
}

data "aws_route53_zone" "main" {
  zone_id = var.hosted_zone_id
}

data "aws_route_tables" "default_vpc" {
  vpc_id = var.vpc_id
}
