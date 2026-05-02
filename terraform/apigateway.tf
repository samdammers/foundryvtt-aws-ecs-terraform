resource "aws_api_gateway_rest_api" "foundry" {
  name        = "Foundry-API"
  description = "FoundryVTT management API"

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = local.tags
}

# /start — ECS scale to 1
resource "aws_api_gateway_resource" "start" {
  rest_api_id = aws_api_gateway_rest_api.foundry.id
  parent_id   = aws_api_gateway_rest_api.foundry.root_resource_id
  path_part   = "start"
}
resource "aws_api_gateway_method" "start" {
  rest_api_id   = aws_api_gateway_rest_api.foundry.id
  resource_id   = aws_api_gateway_resource.start.id
  http_method   = "GET"
  authorization = "NONE"
}
resource "aws_api_gateway_integration" "start" {
  rest_api_id             = aws_api_gateway_rest_api.foundry.id
  resource_id             = aws_api_gateway_resource.start.id
  http_method             = aws_api_gateway_method.start.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.foundry.invoke_arn
  timeout_milliseconds    = 15000
}

# /stop — ECS scale to 0
resource "aws_api_gateway_resource" "stop" {
  rest_api_id = aws_api_gateway_rest_api.foundry.id
  parent_id   = aws_api_gateway_rest_api.foundry.root_resource_id
  path_part   = "stop"
}
resource "aws_api_gateway_method" "stop" {
  rest_api_id   = aws_api_gateway_rest_api.foundry.id
  resource_id   = aws_api_gateway_resource.stop.id
  http_method   = "GET"
  authorization = "NONE"
}
resource "aws_api_gateway_integration" "stop" {
  rest_api_id             = aws_api_gateway_rest_api.foundry.id
  resource_id             = aws_api_gateway_resource.stop.id
  http_method             = aws_api_gateway_method.stop.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.foundry.invoke_arn
  timeout_milliseconds    = 15000
}

# /ip parent
resource "aws_api_gateway_resource" "ip" {
  rest_api_id = aws_api_gateway_rest_api.foundry.id
  parent_id   = aws_api_gateway_rest_api.foundry.root_resource_id
  path_part   = "ip"
}

# /ip/add
resource "aws_api_gateway_resource" "ip_add" {
  rest_api_id = aws_api_gateway_rest_api.foundry.id
  parent_id   = aws_api_gateway_resource.ip.id
  path_part   = "add"
}
resource "aws_api_gateway_method" "ip_add" {
  rest_api_id   = aws_api_gateway_rest_api.foundry.id
  resource_id   = aws_api_gateway_resource.ip_add.id
  http_method   = "GET"
  authorization = "NONE"
}
resource "aws_api_gateway_integration" "ip_add" {
  rest_api_id             = aws_api_gateway_rest_api.foundry.id
  resource_id             = aws_api_gateway_resource.ip_add.id
  http_method             = aws_api_gateway_method.ip_add.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.foundry.invoke_arn
  timeout_milliseconds    = 15000
}

# /ip/reset
resource "aws_api_gateway_resource" "ip_reset" {
  rest_api_id = aws_api_gateway_rest_api.foundry.id
  parent_id   = aws_api_gateway_resource.ip.id
  path_part   = "reset"
}
resource "aws_api_gateway_method" "ip_reset" {
  rest_api_id   = aws_api_gateway_rest_api.foundry.id
  resource_id   = aws_api_gateway_resource.ip_reset.id
  http_method   = "GET"
  authorization = "NONE"
}
resource "aws_api_gateway_integration" "ip_reset" {
  rest_api_id             = aws_api_gateway_rest_api.foundry.id
  resource_id             = aws_api_gateway_resource.ip_reset.id
  http_method             = aws_api_gateway_method.ip_reset.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.foundry.invoke_arn
  timeout_milliseconds    = 15000
}

# Deployment — recreated automatically when any integration changes
resource "aws_api_gateway_deployment" "foundry" {
  rest_api_id = aws_api_gateway_rest_api.foundry.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_integration.start,
      aws_api_gateway_integration.stop,
      aws_api_gateway_integration.ip_add,
      aws_api_gateway_integration.ip_reset,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_cloudwatch_log_group" "apigw" {
  name              = "/aws/apigateway/foundry"
  retention_in_days = 14
  tags              = local.tags
}

resource "aws_api_gateway_stage" "foundry" {
  deployment_id = aws_api_gateway_deployment.foundry.id
  rest_api_id   = aws_api_gateway_rest_api.foundry.id
  stage_name    = "Prod"

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.apigw.arn
    format = jsonencode({
      requestId       = "$context.requestId"
      requestTime     = "$context.requestTime"
      httpMethod      = "$context.httpMethod"
      path            = "$context.path"
      status          = "$context.status"
      responseLatency = "$context.responseLatency"
    })
  }

  depends_on = [aws_api_gateway_account.main]

  tags = local.tags
}

resource "aws_api_gateway_method_settings" "foundry" {
  rest_api_id = aws_api_gateway_rest_api.foundry.id
  stage_name  = aws_api_gateway_stage.foundry.stage_name
  method_path = "*/*"

  settings {
    throttling_burst_limit = 5
    throttling_rate_limit  = 1
  }
}

resource "aws_api_gateway_domain_name" "foundry" {
  domain_name              = local.api_fqdn
  regional_certificate_arn = var.api_cert_arn
  security_policy          = "SecurityPolicy_TLS13_1_3_2025_09"
  endpoint_access_mode     = "BASIC"

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = local.tags
}

resource "aws_api_gateway_base_path_mapping" "foundry" {
  api_id      = aws_api_gateway_rest_api.foundry.id
  stage_name  = aws_api_gateway_stage.foundry.stage_name
  domain_name = aws_api_gateway_domain_name.foundry.domain_name
}

resource "aws_route53_record" "api_foundry" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = local.api_fqdn
  type    = "A"

  alias {
    name                   = aws_api_gateway_domain_name.foundry.regional_domain_name
    zone_id                = aws_api_gateway_domain_name.foundry.regional_zone_id
    evaluate_target_health = false
  }
}
