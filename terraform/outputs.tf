output "alb_dns_name" {
  description = "ALB DNS name — use for manual testing before Route53 is pointed"
  value       = aws_lb.foundry.dns_name
}

output "foundry_url" {
  value = "https://${local.foundry_fqdn}"
}

output "efs_file_system_id" {
  description = "EFS file system ID — needed for world data migration mount command"
  value       = aws_efs_file_system.foundry.id
}

output "efs_dns_name" {
  description = "EFS DNS name — use in the mount command on EC2"
  value       = aws_efs_file_system.foundry.dns_name
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.foundry.name
}

output "ecs_service_name" {
  value = aws_ecs_service.foundry.name
}

output "secrets_manager_arn" {
  description = "ARN of the Foundry credentials secret — populate with put-secret-value"
  value       = aws_secretsmanager_secret.foundry.arn
}

output "api_gateway_execute_url" {
  description = "Direct API Gateway invoke URL (use this until the custom domain is connected)"
  value       = aws_api_gateway_stage.foundry.invoke_url
}
