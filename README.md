# cheche-infrastructure

Terraform infrastructure for **Cheche Technologies** — M-Pesa Statement Converter platform.

> "A spark that ignites financial clarity for Kenyans."

## Architecture

```
User Browser
    │
    ├── PDF extraction (client-side, PDF.js)
    │
    ▼
CloudFront CDN (EYD38S1N9UN3R)
    │
    ├── /index.html        → Landing page
    └── /converter.html    → M-Pesa Converter App
              │
              └── S3 Bucket (cheche-converter-app-dev)
                            us-east-1

Formatted Excel Request
    │
    ▼
API Gateway (vtfoxobw6l) — POST /format
    │
    ▼
Lambda (cheche-excel-formatter)
    ├── Runtime:  Python 3.12
    ├── Memory:   1024 MB
    ├── Timeout:  120 seconds
    ├── Packages: openpyxl + Pillow (manylinux2014_x86_64)
    └── Fonts:    DejaVu Sans (bundled)
```

## Infrastructure Components

| Resource | Name | Notes |
|---|---|---|
| S3 Bucket | `cheche-converter-app-dev` | Static site hosting |
| CloudFront | `EYD38S1N9UN3R` | CDN + HTTPS |
| Lambda | `cheche-excel-formatter` | Excel formatter |
| API Gateway | `vtfoxobw6l` | REST API, prod stage |
| IAM Role | `cheche-lambda-role` | Lambda execution role |

## Terraform Files

| File | Purpose |
|---|---|
| `main.tf` | Provider config, AWS region |
| `variables.tf` | Input variables |
| `s3.tf` | S3 bucket + static site config |
| `cloudfront.tf` | CloudFront distribution |
| `lambda.tf` | Lambda function + IAM role + API Gateway |
| `outputs.tf` | Output values |
| `budget.tf` | AWS billing alerts |

## Deployment

### Prerequisites
- AWS CLI configured (`aws configure`)
- Terraform >= 1.5
- Lambda ZIP package at `./lambda_function.zip`

### Deploy
```bash
terraform init
terraform plan
terraform apply
```

### Update Lambda code only
```powershell
# Rebuild package
cd D:\Cheche\lambda-formatter
cd package
Compress-Archive -Path * -DestinationPath ../lambda_function.zip -Force
cd ..

# Deploy
aws lambda update-function-code `
  --function-name cheche-excel-formatter `
  --zip-file fileb://lambda_function.zip
```

### Invalidate CloudFront cache
```powershell
aws cloudfront create-invalidation `
  --distribution-id EYD38S1N9UN3R `
  --paths "/index.html" "/converter.html"
```

## Product — M-Pesa Statement Converter v4.0

- Extracts transactions from Safaricom M-Pesa PDF statements (client-side)
- Supports password-protected PDFs
- Handles up to 10,000+ transactions (2-year statements tested, 4.4MB)
- Generates 5-sheet raw Excel (All Transactions, Summary, Payee Analysis, Category Breakdown, Top Transactions, Monthly Summary)
- Formatted Excel adds Dashboard sheet with visual charts via Lambda
- Fuliza/Overdraft separated from real cash flow across all sheets
- Freemium model: Free / Pro KES 199 / Business KES 799

## Milestones

| Date | Milestone |
|---|---|
| Jun 06 2026 | Domain `chechetech.co.ke` registered |
| Jun 11 2026 | First Terraform session — repo initialized |
| Jun 15 2026 | Lambda formatter deployed (512MB/60s) |
| Jun 16 2026 | Pillow fix, Fuliza separation, converter redesign |
| Jun 16 2026 | Lambda upgraded to 1024MB/120s |
| Jun 16 2026 | 10,000 transaction stress test passed (2-year statement) |

## Next Steps

- [ ] M-Pesa STK Push integration (Daraja API) — Pro/Business monetisation
- [ ] S3 pre-signed URL upload for large files (>5MB)
- [ ] AWS Cognito auth (phone OTP)
- [ ] DynamoDB usage tracking + free tier enforcement
- [ ] ECS/Docker containerisation of formatter

---

*Managed by Cheche Technologies · chechetech.co.ke · © 2026*
