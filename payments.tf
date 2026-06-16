# ──────────────────────────────────────────────
# DynamoDB — Payment Tracking
# ──────────────────────────────────────────────

resource "aws_dynamodb_table" "cheche_payments" {
  name         = "cheche-payments"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "checkout_request_id"

  attribute {
    name = "checkout_request_id"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = {
    Project     = "cheche-converter"
    Environment = "prod"
    ManagedBy   = "terraform"
  }
}

# ──────────────────────────────────────────────
# IAM — DynamoDB access for Lambda role
# ──────────────────────────────────────────────

resource "aws_iam_role_policy_attachment" "lambda_dynamodb" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess"
}

# ──────────────────────────────────────────────
# Lambda — Payment Callback
# ──────────────────────────────────────────────

resource "aws_lambda_function" "payment_callback" {
  function_name = "cheche-payment-callback"
  role          = aws_iam_role.lambda_role.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.12"
  filename      = "${path.module}/cheche_callback.zip"

  memory_size = 256
  timeout     = 30

  environment {
    variables = {
      DARAJA_CONSUMER_KEY    = var.daraja_consumer_key
      DARAJA_CONSUMER_SECRET = var.daraja_consumer_secret
      DARAJA_SHORTCODE       = var.daraja_shortcode
      DARAJA_PASSKEY         = var.daraja_passkey
      DARAJA_ENV             = var.daraja_env
      DARAJA_CALLBACK_URL    = "https://${aws_api_gateway_rest_api.payments_api.id}.execute-api.${var.aws_region}.amazonaws.com/prod/callback"
    }
  }

  tags = {
    Project     = "cheche-converter"
    Environment = "prod"
    ManagedBy   = "terraform"
  }
}

# ──────────────────────────────────────────────
# API Gateway — Payments API
# ──────────────────────────────────────────────

resource "aws_api_gateway_rest_api" "payments_api" {
  name        = "cheche-payments-api"
  description = "Cheche Technologies M-Pesa Payment API"

  tags = {
    Project     = "cheche-converter"
    Environment = "prod"
    ManagedBy   = "terraform"
  }
}

# /stkpush resource
resource "aws_api_gateway_resource" "stkpush" {
  rest_api_id = aws_api_gateway_rest_api.payments_api.id
  parent_id   = aws_api_gateway_rest_api.payments_api.root_resource_id
  path_part   = "stkpush"
}

# /callback resource
resource "aws_api_gateway_resource" "callback" {
  rest_api_id = aws_api_gateway_rest_api.payments_api.id
  parent_id   = aws_api_gateway_rest_api.payments_api.root_resource_id
  path_part   = "callback"
}

# /status resource
resource "aws_api_gateway_resource" "status" {
  rest_api_id = aws_api_gateway_rest_api.payments_api.id
  parent_id   = aws_api_gateway_rest_api.payments_api.root_resource_id
  path_part   = "status"
}

locals {
  payment_lambda_uri = "arn:aws:apigateway:${var.aws_region}:lambda:path/2015-03-31/functions/${aws_lambda_function.payment_callback.arn}/invocations"
  payment_resources = {
    stkpush  = { id = aws_api_gateway_resource.stkpush.id,  method = "POST" }
    callback = { id = aws_api_gateway_resource.callback.id, method = "POST" }
    status   = { id = aws_api_gateway_resource.status.id,   method = "GET"  }
  }
}

# Methods + integrations
resource "aws_api_gateway_method" "stkpush_post" {
  rest_api_id   = aws_api_gateway_rest_api.payments_api.id
  resource_id   = aws_api_gateway_resource.stkpush.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "stkpush_post" {
  rest_api_id             = aws_api_gateway_rest_api.payments_api.id
  resource_id             = aws_api_gateway_resource.stkpush.id
  http_method             = aws_api_gateway_method.stkpush_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.payment_lambda_uri
}

resource "aws_api_gateway_method" "stkpush_options" {
  rest_api_id   = aws_api_gateway_rest_api.payments_api.id
  resource_id   = aws_api_gateway_resource.stkpush.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "stkpush_options" {
  rest_api_id             = aws_api_gateway_rest_api.payments_api.id
  resource_id             = aws_api_gateway_resource.stkpush.id
  http_method             = aws_api_gateway_method.stkpush_options.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.payment_lambda_uri
}

resource "aws_api_gateway_method" "callback_post" {
  rest_api_id   = aws_api_gateway_rest_api.payments_api.id
  resource_id   = aws_api_gateway_resource.callback.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "callback_post" {
  rest_api_id             = aws_api_gateway_rest_api.payments_api.id
  resource_id             = aws_api_gateway_resource.callback.id
  http_method             = aws_api_gateway_method.callback_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.payment_lambda_uri
}

resource "aws_api_gateway_method" "status_get" {
  rest_api_id   = aws_api_gateway_rest_api.payments_api.id
  resource_id   = aws_api_gateway_resource.status.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "status_get" {
  rest_api_id             = aws_api_gateway_rest_api.payments_api.id
  resource_id             = aws_api_gateway_resource.status.id
  http_method             = aws_api_gateway_method.status_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.payment_lambda_uri
}

resource "aws_api_gateway_method" "status_options" {
  rest_api_id   = aws_api_gateway_rest_api.payments_api.id
  resource_id   = aws_api_gateway_resource.status.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "status_options" {
  rest_api_id             = aws_api_gateway_rest_api.payments_api.id
  resource_id             = aws_api_gateway_resource.status.id
  http_method             = aws_api_gateway_method.status_options.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.payment_lambda_uri
}

# Deployment
resource "aws_api_gateway_deployment" "payments_prod" {
  rest_api_id = aws_api_gateway_rest_api.payments_api.id

  depends_on = [
    aws_api_gateway_integration.stkpush_post,
    aws_api_gateway_integration.stkpush_options,
    aws_api_gateway_integration.callback_post,
    aws_api_gateway_integration.status_get,
    aws_api_gateway_integration.status_options,
  ]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "payments_prod" {
  deployment_id = aws_api_gateway_deployment.payments_prod.id
  rest_api_id   = aws_api_gateway_rest_api.payments_api.id
  stage_name    = "prod"
}

# Lambda permission
resource "aws_lambda_permission" "payments_api_gateway" {
  statement_id  = "AllowPaymentsAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.payment_callback.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.payments_api.execution_arn}/*/*"
}
