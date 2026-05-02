data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/lambda/manager.py"
  output_path = "${path.module}/lambda/handler.zip"
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
      S3_BUCKET   = var.s3_bucket
      ECS_CLUSTER = aws_ecs_cluster.foundry.name
      ECS_SERVICE = aws_ecs_service.foundry.name
    }
  }

  tags = local.tags
}

resource "aws_cloudwatch_event_rule" "ip_reset" {
  name                = "foundry-ip-reset"
  description         = "Reset S3 IP whitelist daily at 1am AEST (3pm UTC)"
  schedule_expression = "cron(0 15 * * ? *)"
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

resource "aws_lambda_permission" "allow_apigw" {
  statement_id  = "AllowAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.foundry.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.foundry.execution_arn}/*/*"
}
