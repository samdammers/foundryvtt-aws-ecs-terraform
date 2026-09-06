# ALB path - active only when use_cloudfront = false. Kept alongside the CloudFront
# path (terraform/cloudfront.tf) rather than removed, for template users without an
# existing CloudFront-based deployment to adopt.
resource "aws_lb" "foundry" {
  count = var.use_cloudfront ? 0 : 1

  name               = "foundry-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb[0].id]
  subnets            = var.subnet_ids

  # Long timeout required for Foundry's persistent WebSocket connections
  idle_timeout = 3600

  enable_deletion_protection = true

  tags = merge(local.tags, { Name = "foundry-alb" })
}

resource "aws_lb_target_group" "foundry" {
  count = var.use_cloudfront ? 0 : 1

  name        = "foundry-tg"
  port        = local.foundry_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip" # Required for Fargate awsvpc networking

  health_check {
    enabled             = true
    path                = "/"
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 10
    interval            = 30
    matcher             = "200-302" # Foundry may redirect / to /game or /setup
  }

  deregistration_delay = 30 # Single task, no need to wait long

  tags = merge(local.tags, { Name = "foundry-tg" })
}

resource "aws_lb_listener" "http" {
  count = var.use_cloudfront ? 0 : 1

  load_balancer_arn = aws_lb.foundry[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  count = var.use_cloudfront ? 0 : 1

  load_balancer_arn = aws_lb.foundry[0].arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.foundry_alb[0].certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.foundry[0].arn
  }
}
