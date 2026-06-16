# ──────────────────────────────────────────────
# IAM Role for Lambda
# ──────────────────────────────────────────────

resource "aws_iam_role" "lambda_role" {
  name = "cheche-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Project     = "cheche-converter"
    Environment = "prod"
    ManagedBy   = "terraform"
  }
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ──────────────────────────────────────────────
# Lambda Function — M-Pesa Excel Formatter
# ──────────────────────────────────────────────

resource "aws_lambda_function" "excel_formatter" {
  function_name = "cheche-excel-formatter"
  role          = aws_iam_role.lambda_role.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.12"
  filename      = "${path.module}/lambda_function.zip"

  memory_size = 1024
  timeout     = 120

  environment {
    variables = {
      ENVIRONMENT = "prod"
    }
  }

  tags = {
    Project     = "cheche-converter"
    Environment = "prod"
    ManagedBy   = "terraform"
  }
}

# ──────────────────────────────────────────────
# API Gateway — REST API
# ──────────────────────────────────────────────

resource "aws_api_gateway_rest_api" "formatter_api" {
  name        = "cheche-formatter-api"
  description = "M-Pesa Excel Formatter API"

  tags = {
    Project     = "cheche-converter"
    Environment = "prod"
    ManagedBy   = "terraform"
  }
}

resource "aws_api_gateway_resource" "format" {
  rest_api_id = aws_api_gateway_rest_api.formatter_api.id
  parent_id   = aws_api_gateway_rest_api.formatter_api.root_resource_id
  path_part   = "format"
}

# POST /format
resource "aws_api_gateway_method" "post_format" {
  rest_api_id   = aws_api_gateway_rest_api.formatter_api.id
  resource_id   = aws_api_gateway_resource.format.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "lambda_integration" {
  rest_api_id             = aws_api_gateway_rest_api.formatter_api.id
  resource_id             = aws_api_gateway_resource.format.id
  http_method             = aws_api_gateway_method.post_format.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.excel_formatter.invoke_arn
}

# OPTIONS /format (CORS preflight)
resource "aws_api_gateway_method" "options_format" {
  rest_api_id   = aws_api_gateway_rest_api.formatter_api.id
  resource_id   = aws_api_gateway_resource.format.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "options_integration" {
  rest_api_id = aws_api_gateway_rest_api.formatter_api.id
  resource_id = aws_api_gateway_resource.format.id
  http_method = aws_api_gateway_method.options_format.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "options_200" {
  rest_api_id = aws_api_gateway_rest_api.formatter_api.id
  resource_id = aws_api_gateway_resource.format.id
  http_method = aws_api_gateway_method.options_format.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "options_integration_response" {
  rest_api_id = aws_api_gateway_rest_api.formatter_api.id
  resource_id = aws_api_gateway_resource.format.id
  http_method = aws_api_gateway_method.options_format.http_method
  status_code = aws_api_gateway_method_response.options_200.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
}

# Deployment
resource "aws_api_gateway_deployment" "prod" {
  rest_api_id = aws_api_gateway_rest_api.formatter_api.id

  depends_on = [
    aws_api_gateway_integration.lambda_integration,
    aws_api_gateway_integration.options_integration,
  ]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "prod" {
  deployment_id = aws_api_gateway_deployment.prod.id
  rest_api_id   = aws_api_gateway_rest_api.formatter_api.id
  stage_name    = "prod"
}

# Lambda permission for API Gateway
resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.excel_formatter.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.formatter_api.execution_arn}/*/*"
}
