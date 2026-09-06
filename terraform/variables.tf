variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
}

variable "domain" {
  description = "Root domain name (e.g. example.com)"
  type        = string
}

variable "hosted_zone_id" {
  description = "Route53 hosted zone ID for your domain"
  type        = string
}

variable "s3_bucket" {
  description = "S3 bucket name for FoundryVTT game assets (must be globally unique)"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID to deploy into"
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs (one per AZ) for ECS tasks and EFS mount targets"
  type        = list(string)
}

variable "vpc_subnet_cidrs" {
  description = "CIDR blocks of your subnets - added to S3 bucket policy to allow ECS task access to assets"
  type        = list(string)
}

variable "api_cert_arn" {
  description = "ACM certificate ARN for api.<domain> in the deployment region"
  type        = string
}

variable "use_cloudfront" {
  description = "Edge architecture for foundry.<domain>: true = CloudFront (default, lower fixed cost, needs the dynamic-origin-DNS Lambda), false = ALB (simpler, stable DNS, ~$20/month fixed)"
  type        = bool
  default     = true
}

variable "manage_api_gateway_account" {
  description = "Whether this stack creates the account-level API Gateway CloudWatch logging role (aws_api_gateway_account) - a singleton per AWS account/region. Leave true unless another Terraform stack already manages it in this account, in which case set false here to avoid two stacks fighting over the same resource."
  type        = bool
  default     = true
}

variable "fargate_cpu" {
  description = "ECS task CPU units (1024 = 1 vCPU)"
  type        = number
  default     = 1024
}

variable "fargate_memory" {
  description = "ECS task memory in MB"
  type        = number
  default     = 2048
}

variable "foundry_image" {
  description = "FoundryVTT container image tag"
  type        = string
  default     = "ghcr.io/felddy/foundryvtt:14"
}

variable "foundry_world" {
  description = "World name to auto-launch on startup - must match the folder name under Data/worlds/"
  type        = string
}

variable "timezone" {
  description = "Container timezone (e.g. Australia/Melbourne, America/New_York)"
  type        = string
  default     = "UTC"
}

variable "auto_stop_schedule" {
  description = "EventBridge cron (UTC) for auto-stopping ECS. Default: 3pm UTC (adjust for your timezone)."
  type        = string
  default     = "cron(0 15 * * ? *)"
}

variable "ip_reset_schedule" {
  description = "EventBridge cron (UTC) for resetting the S3 asset IP allowlist back to just the VPC CIDRs. The bucket policy exists to keep game assets (maps, tokens, etc.) away from the open internet, not to gate individual sessions - a tighter schedule (the daily default) suits a public template best, but a longer interval (e.g. yearly) trades some of that protection for less friction if your players don't rotate IPs often. Default: daily at 3pm UTC."
  type        = string
  default     = "cron(0 15 * * ? *)"
}

variable "container_hostname" {
  description = "Hostname written into options.json for Foundry license binding - use your permanent production hostname (e.g. foundry.example.com)"
  type        = string
}

variable "repo" {
  description = "Repository URL for the repo tag applied to all resources"
  type        = string
  default     = "samdammers/foundryvtt-aws-ecs-terraform"
}

variable "discord_public_key" {
  description = "Optional: Discord application public key (hex, from the same Developer Portal page) - verifies Ed25519-signed interaction requests. Not secret; Discord expects this to be public. Leave blank to skip the Discord slash-command integration (the /discord route will just reject every request with 401)."
  type        = string
  default     = ""
}

variable "discord_webhook_url" {
  description = "Optional Discord webhook for server start/stop notifications"
  type        = string
  default     = ""
  sensitive   = true
}
