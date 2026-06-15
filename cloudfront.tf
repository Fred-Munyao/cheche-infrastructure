# SSL Certificate — must be in us-east-1 for CloudFront
resource "aws_acm_certificate" "cheche_cert" {
  domain_name               = "chechetech.co.ke"
  subject_alternative_names = ["www.chechetech.co.ke"]
  validation_method         = "DNS"

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "Terraform"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# CloudFront Origin Access Control
resource "aws_cloudfront_origin_access_control" "cheche_oac" {
  name                              = "cheche-s3-oac"
  description                       = "OAC for Cheche S3 bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# CloudFront Distribution
resource "aws_cloudfront_distribution" "cheche_cdn" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  price_class         = "PriceClass_100"
  comment             = "Cheche Technologies M-Pesa Converter CDN"

  aliases = ["chechetech.co.ke", "www.chechetech.co.ke"]

  origin {
    domain_name              = aws_s3_bucket.cheche_app.bucket_regional_domain_name
    origin_id                = "cheche-s3-origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.cheche_oac.id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "cheche-s3-origin"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 3600
    max_ttl     = 86400
  }

  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate.cheche_cert.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "Terraform"
  }

  depends_on = [aws_acm_certificate.cheche_cert]
}