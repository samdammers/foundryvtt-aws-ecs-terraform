resource "aws_s3_bucket" "foundry" {
  bucket = var.s3_bucket
  tags   = local.tags
}

resource "aws_s3_bucket_server_side_encryption_configuration" "foundry" {
  bucket = aws_s3_bucket.foundry.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "foundry" {
  bucket = aws_s3_bucket.foundry.id

  block_public_acls       = false
  ignore_public_acls      = false
  block_public_policy     = false
  restrict_public_buckets = false
}

# Base policy — VPC subnet CIDRs only. Lambda dynamically adds/removes IPs via
# /ip/add and /ip/reset; ignore_changes prevents terraform apply from wiping
# those transient entries.
resource "aws_s3_bucket_policy" "foundry" {
  bucket = aws_s3_bucket.foundry.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicReadGetObject"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.foundry.arn}/*"
      Condition = {
        IpAddress = {
          "aws:SourceIp" = var.vpc_subnet_cidrs
        }
      }
    }]
  })

  lifecycle {
    ignore_changes = [policy]
  }
}
