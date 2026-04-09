data "aws_region" "current" {}

# ========= REST API =========
resource "aws_api_gateway_rest_api" "storage_api" {
  name        = "cloudsentrics-automated-storage-api"
  description = "API for receiving files from customer software (CBT, EMR, LIS, EMS)"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

# /v1
resource "aws_api_gateway_resource" "v1" {
  rest_api_id = aws_api_gateway_rest_api.storage_api.id
  parent_id   = aws_api_gateway_rest_api.storage_api.root_resource_id
  path_part   = "v1"
}

# /v1/upload
resource "aws_api_gateway_resource" "upload" {
  rest_api_id = aws_api_gateway_rest_api.storage_api.id
  parent_id   = aws_api_gateway_resource.v1.id
  path_part   = "upload"
}

# POST /v1/upload
resource "aws_api_gateway_method" "upload_post" {
  rest_api_id      = aws_api_gateway_rest_api.storage_api.id
  resource_id      = aws_api_gateway_resource.upload.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = true
}

# Lambda integration
resource "aws_api_gateway_integration" "upload_lambda" {
  rest_api_id             = aws_api_gateway_rest_api.storage_api.id
  resource_id             = aws_api_gateway_resource.upload.id
  http_method             = aws_api_gateway_method.upload_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = "arn:aws:apigateway:${data.aws_region.current.name}:lambda:path/2015-03-31/functions/${module.storage_ingestion_lambda.lambda_function_arn}/invocations"
}

# Lambda permission for API Gateway
resource "aws_lambda_permission" "api_gateway_invoke" {
  action        = "lambda:InvokeFunction"
  function_name = module.storage_ingestion_lambda.lambda_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.storage_api.execution_arn}/*/*"
}

# ========= Deployment & Stage =========
resource "aws_api_gateway_deployment" "storage_api_deployment" {
  rest_api_id = aws_api_gateway_rest_api.storage_api.id

  depends_on = [
    aws_api_gateway_integration.upload_lambda
  ]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "prod" {
  rest_api_id   = aws_api_gateway_rest_api.storage_api.id
  deployment_id = aws_api_gateway_deployment.storage_api_deployment.id
  stage_name    = "prod"
}

# ========= Usage Plan & API Key =========
resource "aws_api_gateway_usage_plan" "storage_plan" {
  name        = "cloudsentrics-automated-storage-plan"
  description = "Usage plan for automated storage API"

  api_stages {
    api_id = aws_api_gateway_rest_api.storage_api.id
    stage  = aws_api_gateway_stage.prod.stage_name
  }

  throttle_settings {
    burst_limit = 50
    rate_limit  = 100
  }
}

resource "aws_api_gateway_api_key" "customer_key" {
  name    = "cloudsentrics-automated-storage-key"
  enabled = true
}

resource "aws_api_gateway_usage_plan_key" "customer_plan_key" {
  key_id        = aws_api_gateway_api_key.customer_key.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.storage_plan.id
}
