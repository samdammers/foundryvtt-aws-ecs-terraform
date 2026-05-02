# --- ALB Security Group ---
resource "aws_security_group" "alb" {
  name        = "foundry-alb-sg"
  description = "ALB: HTTP/HTTPS from internet"
  vpc_id      = var.vpc_id
  tags        = merge(local.tags, { Name = "foundry-alb-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_out" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --- ECS Task Security Group ---
resource "aws_security_group" "ecs_task" {
  name        = "foundry-ecs-task-sg"
  description = "Fargate task: inbound on 30000 from ALB only, all outbound"
  vpc_id      = var.vpc_id
  tags        = merge(local.tags, { Name = "foundry-ecs-task-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "ecs_from_alb" {
  security_group_id            = aws_security_group.ecs_task.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = local.foundry_port
  to_port                      = local.foundry_port
  ip_protocol                  = "tcp"
}

# Fargate needs unrestricted outbound: pull ghcr.io image, reach AWS APIs (Secrets Manager,
# EFS, CloudWatch), and download the FoundryVTT distribution on first start.
resource "aws_vpc_security_group_egress_rule" "ecs_out" {
  security_group_id = aws_security_group.ecs_task.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --- EFS Security Group ---
resource "aws_security_group" "efs" {
  name        = "foundry-efs-sg"
  description = "EFS: NFS from ECS tasks only"
  vpc_id      = var.vpc_id
  tags        = merge(local.tags, { Name = "foundry-efs-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "efs_nfs" {
  security_group_id            = aws_security_group.efs.id
  referenced_security_group_id = aws_security_group.ecs_task.id
  from_port                    = 2049
  to_port                      = 2049
  ip_protocol                  = "tcp"
}
