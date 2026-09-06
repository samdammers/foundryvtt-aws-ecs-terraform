# PyNaCl (Ed25519 signature verification for Discord interactions) has no pure-Python
# option we want to hand-roll, and Lambda's runtime doesn't bundle it - so vendor it in
# directly rather than depending on a third-party Lambda Layer of uncertain regional
# availability. Re-runs only when requirements.txt changes. Targets the aarch64 wheel
# to match this Lambda's arm64 architecture (same as the ECS task).
resource "null_resource" "lambda_dependencies" {
  triggers = {
    requirements_hash = filesha256("${path.module}/lambda/requirements.txt")
  }

  provisioner "local-exec" {
    command = <<-EOT
      python3 -m pip install -r ${path.module}/lambda/requirements.txt \
        --target ${path.module}/lambda \
        --platform manylinux2014_aarch64 \
        --implementation cp \
        --python-version 3.12 \
        --abi cp312 \
        --only-binary=:all: \
        --upgrade -q
    EOT
  }
}

data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/lambda/handler.zip"
  excludes    = ["requirements.txt", "handler.zip"]

  depends_on = [null_resource.lambda_dependencies]
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/foundry-manager"
  retention_in_days = 14
  tags              = local.tags
}

resource "aws_lambda_function" "foundry" {
  function_name    = "foundry-manager"
  description      = "Manage FoundryVTT EC2 and ECS resources"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  handler     = "manager.lambda_handler"
  runtime     = "python3.12"
  timeout     = 120
  memory_size = 128
  role        = aws_iam_role.lambda.arn

  architectures = ["arm64"]

  environment {
    variables = {
      S3_BUCKET           = var.s3_bucket
      ECS_CLUSTER         = aws_ecs_cluster.foundry.name
      ECS_SERVICE         = aws_ecs_service.foundry.name
      HOSTED_ZONE_ID      = var.hosted_zone_id
      ORIGIN_RECORD       = local.origin_fqdn
      DISCORD_PUBLIC_KEY  = var.discord_public_key
      DISCORD_WEBHOOK_URL = var.discord_webhook_url
      FOUNDRY_URL         = "https://${local.foundry_fqdn}"
      IP_ADD_URL          = "https://${local.api_fqdn}/ip/add"
    }
  }

  tags = local.tags
}

resource "aws_cloudwatch_event_rule" "ip_reset" {
  name                = "foundry-ip-reset"
  description         = "Reset the S3 asset IP allowlist on ip_reset_schedule"
  schedule_expression = var.ip_reset_schedule
  tags                = local.tags
}

resource "aws_cloudwatch_event_target" "ip_reset" {
  rule      = aws_cloudwatch_event_rule.ip_reset.name
  target_id = "foundry-lambda"
  arn       = aws_lambda_function.foundry.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.foundry.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.ip_reset.arn
}

resource "aws_cloudwatch_event_rule" "ecs_auto_stop" {
  name                = "foundry-ecs-auto-stop"
  description         = "Auto-stop FoundryVTT ECS service on schedule (default: 1am AEST)"
  schedule_expression = var.auto_stop_schedule
  tags                = local.tags
}

resource "aws_cloudwatch_event_target" "ecs_auto_stop" {
  rule      = aws_cloudwatch_event_rule.ecs_auto_stop.name
  target_id = "foundry-lambda"
  arn       = aws_lambda_function.foundry.arn
  input     = jsonencode({ scheduled_action = "ecs_stop" })
}

resource "aws_lambda_permission" "allow_eventbridge_ecs_stop" {
  statement_id  = "AllowEventBridgeEcsStop"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.foundry.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.ecs_auto_stop.arn
}

# Fires when the ECS task reaches RUNNING - active only when use_cloudfront = true,
# since only the CloudFront path needs the origin Route53 record kept up to date
# with the task's current public IP (the ALB path has a stable DNS name instead).
resource "aws_cloudwatch_event_rule" "ecs_task_running" {
  count = var.use_cloudfront ? 1 : 0

  name        = "foundry-ecs-task-running"
  description = "Fire when a Foundry ECS task reaches RUNNING - Lambda updates origin DNS record"

  event_pattern = jsonencode({
    source      = ["aws.ecs"]
    detail-type = ["ECS Task State Change"]
    detail = {
      clusterArn = [aws_ecs_cluster.foundry.arn]
      lastStatus = ["RUNNING"]
    }
  })

  tags = local.tags
}

resource "aws_cloudwatch_event_target" "ecs_task_running" {
  count = var.use_cloudfront ? 1 : 0

  rule      = aws_cloudwatch_event_rule.ecs_task_running[0].name
  target_id = "foundry-lambda-dns"
  arn       = aws_lambda_function.foundry.arn
}

resource "aws_lambda_permission" "allow_eventbridge_ecs_running" {
  count = var.use_cloudfront ? 1 : 0

  statement_id  = "AllowEventBridgeEcsRunning"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.foundry.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.ecs_task_running[0].arn
}

resource "aws_lambda_permission" "allow_apigw" {
  statement_id  = "AllowAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.foundry.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.foundry.execution_arn}/*/*"
}
