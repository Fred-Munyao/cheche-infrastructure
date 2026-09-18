# ──────────────────────────────────────────────
# IAM Role for Lambda (shared by both functions)
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
# Formatter API — HTTP API (API Gateway v2)
# Matches what is actually live: vtfoxobw6l, POST /format, stage prod, auto-deploy
# ──────────────────────────────────────────────

resource "aws_apigatewayv2_api" "formatter_api" {
  name          = "cheche-formatter-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_headers = ["content-type"]
    allow_methods = ["POST", "OPTIONS"]
    allow_origins = ["*"]
  }
}

resource "aws_apigatewayv2_integration" "formatter" {
  api_id                 = aws_apigatewayv2_api.formatter_api.id
  integration_type       = "AWS_PROXY"
  integration_method     = "POST"
  integration_uri        = aws_lambda_function.excel_formatter.arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 30000   # HTTP API hard maximum — see note in runbook
}

resource "aws_apigatewayv2_route" "post_format" {
  api_id    = aws_apigatewayv2_api.formatter_api.id
  route_key = "POST /format"
  target    = "integrations/${aws_apigatewayv2_integration.formatter.id}"
}

resource "aws_apigatewayv2_stage" "prod" {
  api_id      = aws_apigatewayv2_api.formatter_api.id
  name        = "prod"
  auto_deploy = true
}

# Statement ID matches the live permission, so it is imported, not replaced
resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "apigateway-invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.excel_formatter.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.formatter_api.execution_arn}/*"
}
