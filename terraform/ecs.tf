resource "aws_cloudwatch_log_group" "foundry_ecs" {
  name              = "/ecs/foundry"
  retention_in_days = 14
  tags              = local.tags
}

resource "aws_ecs_cluster" "foundry" {
  name = "foundry"

  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  tags = local.tags
}

resource "aws_ecs_task_definition" "foundry" {
  family                   = "foundry"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.fargate_cpu
  memory                   = var.fargate_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  # ARM64 is available in ap-southeast-4 and matches the existing EC2 (t4g.small).
  # Change to X86_64 if you hit Fargate capacity errors.
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  volume {
    name = "foundry-data"

    efs_volume_configuration {
      file_system_id          = aws_efs_file_system.foundry.id
      transit_encryption      = "ENABLED"
      transit_encryption_port = 2049
      authorization_config {
        access_point_id = aws_efs_access_point.foundry.id
        iam             = "ENABLED"
      }
    }
  }

  container_definitions = jsonencode([
    {
      name      = "foundry"
      image     = var.foundry_image
      essential = true

      portMappings = [
        {
          containerPort = local.foundry_port
          protocol      = "tcp"
        }
      ]

      environment = [
        # Prevent the container from overwriting options.json on restart
        { name = "CONTAINER_PRESERVE_CONFIG", value = "true" },
        { name = "FOUNDRY_WORLD", value = var.foundry_world },
        # Foundry writes this into options.json as the hostname — license binds to it.
        # Use the permanent production hostname so no re-licensing is needed after cutover.
        { name = "FOUNDRY_HOSTNAME", value = var.container_hostname },
        # Tell Foundry it's behind an HTTPS proxy
        { name = "FOUNDRY_PROXY_SSL", value = "true" },
        { name = "FOUNDRY_PROXY_PORT", value = "443" },
        { name = "TZ", value = var.timezone },
        # Cache the downloaded distribution so restarts are faster
        { name = "CONTAINER_CACHE", value = "/data/container_cache" },
      ]

      # Credentials injected from Secrets Manager — never appear in logs or task metadata
      secrets = [
        {
          name      = "FOUNDRY_USERNAME"
          valueFrom = "${aws_secretsmanager_secret.foundry.arn}:username::"
        },
        {
          name      = "FOUNDRY_PASSWORD"
          valueFrom = "${aws_secretsmanager_secret.foundry.arn}:password::"
        },
        {
          name      = "FOUNDRY_ADMIN_KEY"
          valueFrom = "${aws_secretsmanager_secret.foundry.arn}:admin_key::"
        },
      ]

      mountPoints = [
        {
          sourceVolume  = "foundry-data"
          containerPath = "/data"
          readOnly      = false
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/foundry"
          "awslogs-region"        = local.region
          "awslogs-stream-prefix" = "foundry"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:30000/api/status || exit 1"]
        interval    = 30
        timeout     = 10
        retries     = 3
        startPeriod = 60
      }
    }
  ])

  tags = local.tags
}

resource "aws_ecs_service" "foundry" {
  name                              = "foundry"
  cluster                           = aws_ecs_cluster.foundry.id
  task_definition                   = aws_ecs_task_definition.foundry.arn
  launch_type                       = "FARGATE"
  desired_count                     = 0 # Scale to 1 after world data is on EFS and secrets are set
  health_check_grace_period_seconds = 120

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.ecs_task.id]
    assign_public_ip = true # Required — default VPC has no NAT gateway
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.foundry.arn
    container_name   = "foundry"
    container_port   = local.foundry_port
  }

  force_new_deployment   = true
  enable_execute_command = true

  lifecycle {
    # Prevent terraform apply from resetting desired_count back to 0 after you scale it up
    ignore_changes = [desired_count]
  }

  depends_on = [
    aws_lb_listener.https,
    aws_iam_role_policy_attachment.ecs_task_execution_managed,
  ]

  tags = local.tags
}
