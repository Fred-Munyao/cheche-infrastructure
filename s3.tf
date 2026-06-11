# S3 bucket to host the Cheche converter app
resource "aws_s3_bucket" "cheche_app" {
  bucket = "${var.project}-converter-app-${var.environment}"

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# Disable block public access so CloudFront can read the files
resource "aws_s3_bucket_public_access_block" "cheche_app" {
  bucket = aws_s3_bucket.cheche_app.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# Enable static website hosting
resource "aws_s3_bucket_website_configuration" "cheche_app" {
  bucket = aws_s3_bucket.cheche_app.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "index.html"
  }
}

# Bucket policy — allows public read access
resource "aws_s3_bucket_policy" "cheche_app" {
  bucket = aws_s3_bucket.cheche_app.id

  depends_on = [aws_s3_bucket_public_access_block.cheche_app]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.cheche_app.arn}/*"
      }
    ]
  })
}