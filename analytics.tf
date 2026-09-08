# ──────────────────────────────────────────────
# DynamoDB — Usage Analytics (anonymous client events)
# ──────────────────────────────────────────────
# Stores product usage events keyed by an anonymous client_id
# generated in the browser. No statement contents are ever written here.
# Events link to an MSISDN only via cheche-payments.client_id once a user pays.

resource "aws_dynamodb_table" "cheche_analytics" {
  name         = "cheche-analytics"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "client_id"
  range_key    = "sk"

  attribute {
    name = "client_id"
    type = "S"
  }

  attribute {
    name = "sk" # "<epoch_ms>#<event>"
    type = "S"
  }

  attribute {
    name = "event"
    type = "S"
  }

  attribute {
    name = "ts"
    type = "N"
  }

  # Query all events of one type across all clients, ordered by time
  global_secondary_index {
    name            = "event-index"
    hash_key        = "event"
    range_key       = "ts"
    projection_type = "ALL"
  }

  # Events expire 18 months after being written
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
# API Gateway — POST /track on the payments API
# ──────────────────────────────────────────────

resource "aws_api_gateway_resource" "track" {
  rest_api_id = aws_api_gateway_rest_api.payments_api.id
  parent_id   = aws_api_gateway_rest_api.payments_api.root_resource_id
  path_part   = "track"
}

resource "aws_api_gateway_method" "track_post" {
  rest_api_id   = aws_api_gateway_rest_api.payments_api.id
  resource_id   = aws_api_gateway_resource.track.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "track_post" {
  rest_api_id             = aws_api_gateway_rest_api.payments_api.id
  resource_id             = aws_api_gateway_resource.track.id
  http_method             = aws_api_gateway_method.track_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.payment_lambda_uri
}

resource "aws_api_gateway_method" "track_options" {
  rest_api_id   = aws_api_gateway_rest_api.payments_api.id
  resource_id   = aws_api_gateway_resource.track.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "track_options" {
  rest_api_id             = aws_api_gateway_rest_api.payments_api.id
  resource_id             = aws_api_gateway_resource.track.id
  http_method             = aws_api_gateway_method.track_options.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.payment_lambda_uri
}
