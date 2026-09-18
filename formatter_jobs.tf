# ─────────────────────────────────────────────────────────────
# Async formatter: private job bucket + routes + S3 trigger
#   in/   raw workbook uploaded by the browser (deleted right after the build)
#   out/  finished workbook (downloaded via 10-minute links)
#   jobs/ err/  small JSON job records
# Everything expires after 1 day.
# ─────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "formatter_jobs" {
  bucket = "cheche-formatter-jobs-507629158424"

  tags = {
    Project     = "cheche-converter"
    Environment = "prod"
    ManagedBy   = "terraform"
  }
}

resource "aws_s3_bucket_public_access_block" "formatter_jobs" {
  bucket                  = aws_s3_bucket.formatter_jobs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "formatter_jobs" {
  bucket = aws_s3_bucket.formatter_jobs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "formatter_jobs" {
  bucket = aws_s3_bucket.formatter_jobs.id
  rule {
    id     = "expire-everything-after-1-day"
    status = "Enabled"
    filter {}
    expiration {
      days = 1
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# Browser uploads with a signed form (POST); downloads are plain links (no CORS needed)
resource "aws_s3_bucket_cors_configuration" "formatter_jobs" {
  bucket = aws_s3_bucket.formatter_jobs.id
  cors_rule {
    allowed_methods = ["POST"]
    allowed_origins = ["https://chechetech.co.ke", "https://www.chechetech.co.ke", "null"]  # "null" = demo page opened from disk
    allowed_headers = ["*"]
    max_age_seconds = 3000
  }
}

# Lambda may read/write/delete job objects only in this bucket
resource "aws_iam_role_policy" "formatter_jobs_s3" {
  name = "cheche-formatter-jobs-s3"
  role = aws_iam_role.lambda_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.formatter_jobs.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]            # lets "not found" come back as 404 instead of 403
        Resource = aws_s3_bucket.formatter_jobs.arn
      }
    ]
  })
}

# S3 upload -> formatter (asynchronous invoke)
resource "aws_lambda_permission" "formatter_s3" {
  statement_id  = "s3-invoke-formatter"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.excel_formatter.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.formatter_jobs.arn
}

resource "aws_s3_bucket_notification" "formatter_jobs" {
  bucket = aws_s3_bucket.formatter_jobs.id
  lambda_function {
    lambda_function_arn = aws_lambda_function.excel_formatter.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "in/"
    filter_suffix       = ".xlsx"
  }
  depends_on = [aws_lambda_permission.formatter_s3]
}

# No automatic retries: a retry could take a second paid slot. Failures are reported to the browser instead.
resource "aws_lambda_function_event_invoke_config" "formatter" {
  function_name                = aws_lambda_function.excel_formatter.function_name
  maximum_retry_attempts       = 0
  maximum_event_age_in_seconds = 300
}

# New API routes on the existing HTTP API (stage auto-deploys)
resource "aws_apigatewayv2_route" "post_jobs" {
  api_id    = aws_apigatewayv2_api.formatter_api.id
  route_key = "POST /jobs"
  target    = "integrations/${aws_apigatewayv2_integration.formatter.id}"
}

resource "aws_apigatewayv2_route" "get_job" {
  api_id    = aws_apigatewayv2_api.formatter_api.id
  route_key = "GET /jobs/{id}"
  target    = "integrations/${aws_apigatewayv2_integration.formatter.id}"
}

output "formatter_jobs_bucket" {
  value = aws_s3_bucket.formatter_jobs.bucket
}
