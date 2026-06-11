output "bucket_name" {
  description = "Name of the S3 bucket"
  value       = aws_s3_bucket.cheche_app.id
}

output "website_url" {
  description = "S3 static website URL"
  value       = aws_s3_bucket_website_configuration.cheche_app.website_endpoint
}