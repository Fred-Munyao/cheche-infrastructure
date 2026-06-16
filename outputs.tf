# ──────────────────────────────────────────────
# Outputs — Cheche Technologies Infrastructure
# ──────────────────────────────────────────────

output "s3_bucket_name" {
  description = "S3 bucket hosting the converter app"
  value       = aws_s3_bucket.converter_app.bucket
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID"
  value       = aws_cloudfront_distribution.converter_cdn.id
}

output "cloudfront_domain" {
  description = "CloudFront domain name"
  value       = aws_cloudfront_distribution.converter_cdn.domain_name
}

output "lambda_function_name" {
  description = "Lambda formatter function name"
  value       = aws_lambda_function.excel_formatter.function_name
}

output "lambda_function_arn" {
  description = "Lambda formatter function ARN"
  value       = aws_lambda_function.excel_formatter.arn
}

output "api_gateway_endpoint" {
  description = "API Gateway endpoint for the formatter"
  value       = "https://${aws_api_gateway_rest_api.formatter_api.id}.execute-api.${var.aws_region}.amazonaws.com/${aws_api_gateway_stage.prod.stage_name}/format"
}

output "api_gateway_id" {
  description = "API Gateway REST API ID"
  value       = aws_api_gateway_rest_api.formatter_api.id
}
