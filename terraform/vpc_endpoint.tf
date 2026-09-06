# S3 Gateway VPC Endpoint - routes Fargate-to-S3 traffic within the VPC.
#
# Without this, Fargate tasks (assign_public_ip=true) reach S3 via their public
# ENI IP, which is NOT in 172.31.0.0/16. The existing S3 bucket policy restricts
# access to those VPC CIDRs, so tasks would be blocked. The Gateway endpoint is
# free and makes S3 traffic appear to originate from within the VPC.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${local.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = data.aws_route_tables.default_vpc.ids

  tags = merge(local.tags, { Name = "foundry-s3-endpoint" })
}
