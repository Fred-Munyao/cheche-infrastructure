# Outputs - aligned with the resources actually defined in this repo

output "s3_bucket_name" {
  description = "Static site bucket"
  value       = aws_s3_bucket.cheche_app.bucket
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution (use for invalidations)"
  value       = aws_cloudfront_distribution.cheche_cdn.id
}

output "cloudfront_domain" {
  description = "CloudFront domain name"
  value       = aws_cloudfront_distribution.cheche_cdn.domain_name
}

output "formatter_api_id" {
  description = "Formatter HTTP API (API Gateway v2)"
  value       = aws_apigatewayv2_api.formatter_api.id
}

output "formatter_api_endpoint" {
  description = "POST endpoint used by converter.html for the formatted workbook"
  value       = "${aws_apigatewayv2_stage.prod.invoke_url}/format"
}

output "payments_api_id" {
  description = "Payments REST API (API Gateway v1)"
  value       = aws_api_gateway_rest_api.payments_api.id
}

output "payments_api_endpoint" {
  description = "Base URL for /stkpush, /status, /callback, /track"
  value       = aws_api_gateway_stage.payments_prod.invoke_url
}
