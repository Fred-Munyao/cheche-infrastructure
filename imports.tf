# ─────────────────────────────────────────────────────────────
# One-time import of live Cheche resources into Terraform state.
# After a clean apply, this file can be deleted (imports are idempotent,
# but removing it keeps the repo tidy).
# ─────────────────────────────────────────────────────────────

# ── S3 static site ──
import {
  to = aws_s3_bucket.cheche_app
  id = "cheche-converter-app-dev"
}
import {
  to = aws_s3_bucket_public_access_block.cheche_app
  id = "cheche-converter-app-dev"
}
import {
  to = aws_s3_bucket_website_configuration.cheche_app
  id = "cheche-converter-app-dev"
}
import {
  to = aws_s3_bucket_policy.cheche_app
  id = "cheche-converter-app-dev"
}

# ── CloudFront + ACM ──
import {
  to = aws_acm_certificate.cheche_cert
  id = "arn:aws:acm:us-east-1:507629158424:certificate/eabf6946-6bac-4fb5-8d5a-0257df1fd2d3"
}
import {
  to = aws_cloudfront_origin_access_control.cheche_oac
  id = "E2SZFLCZUJGQI9"
}
import {
  to = aws_cloudfront_distribution.cheche_cdn
  id = "EYD38S1N9UN3R"
}

# ── Budget ──
import {
  to = aws_budgets_budget.monthly_limit
  id = "507629158424:cheche-monthly-budget"
}

# ── IAM ──
import {
  to = aws_iam_role.lambda_role
  id = "cheche-lambda-role"
}
import {
  to = aws_iam_role_policy_attachment.lambda_basic
  id = "cheche-lambda-role/arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
# aws_iam_role_policy.lambda_dynamodb does not exist live -> will be CREATED (scoped policy)

# ── Formatter: Lambda + HTTP API (v2) ──
import {
  to = aws_lambda_function.excel_formatter
  id = "cheche-excel-formatter"
}
import {
  to = aws_apigatewayv2_api.formatter_api
  id = "vtfoxobw6l"
}
import {
  to = aws_apigatewayv2_integration.formatter
  id = "vtfoxobw6l/frxzf8q"
}
import {
  to = aws_apigatewayv2_route.post_format
  id = "vtfoxobw6l/qjr8jxr"
}
import {
  to = aws_apigatewayv2_stage.prod
  id = "vtfoxobw6l/prod"
}
import {
  to = aws_lambda_permission.api_gateway
  id = "cheche-excel-formatter/apigateway-invoke"
}

# ── Payments: DynamoDB + Lambda ──
import {
  to = aws_dynamodb_table.cheche_payments
  id = "cheche-payments"
}
import {
  to = aws_lambda_function.payment_callback
  id = "cheche-payment-callback"
}
import {
  to = aws_lambda_permission.payments_api_gateway
  id = "cheche-payment-callback/apigateway-invoke"
}

# ── Payments REST API (v1): jkv6ay89l0 ──
import {
  to = aws_api_gateway_rest_api.payments_api
  id = "jkv6ay89l0"
}
import {
  to = aws_api_gateway_resource.stkpush
  id = "jkv6ay89l0/sycko3"
}
import {
  to = aws_api_gateway_resource.callback
  id = "jkv6ay89l0/7jgo8w"
}
import {
  to = aws_api_gateway_resource.status
  id = "jkv6ay89l0/u58gq9"
}
import {
  to = aws_api_gateway_method.stkpush_post
  id = "jkv6ay89l0/sycko3/POST"
}
import {
  to = aws_api_gateway_integration.stkpush_post
  id = "jkv6ay89l0/sycko3/POST"
}
import {
  to = aws_api_gateway_method.stkpush_options
  id = "jkv6ay89l0/sycko3/OPTIONS"
}
import {
  to = aws_api_gateway_integration.stkpush_options
  id = "jkv6ay89l0/sycko3/OPTIONS"
}
import {
  to = aws_api_gateway_method.callback_post
  id = "jkv6ay89l0/7jgo8w/POST"
}
import {
  to = aws_api_gateway_integration.callback_post
  id = "jkv6ay89l0/7jgo8w/POST"
}
import {
  to = aws_api_gateway_method.status_get
  id = "jkv6ay89l0/u58gq9/GET"
}
import {
  to = aws_api_gateway_integration.status_get
  id = "jkv6ay89l0/u58gq9/GET"
}
import {
  to = aws_api_gateway_method.status_options
  id = "jkv6ay89l0/u58gq9/OPTIONS"
}
import {
  to = aws_api_gateway_integration.status_options
  id = "jkv6ay89l0/u58gq9/OPTIONS"
}
import {
  to = aws_api_gateway_deployment.payments_prod
  id = "jkv6ay89l0/23u4ov"
}
import {
  to = aws_api_gateway_stage.payments_prod
  id = "jkv6ay89l0/prod"
}

# NOT imported (do not exist yet -> CREATED): cheche-analytics table,
# /track resource + methods + integrations, scoped DynamoDB inline policy.
