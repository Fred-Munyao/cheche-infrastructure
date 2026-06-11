# Cheche Technologies — AWS Infrastructure

Infrastructure as Code (Terraform) for Cheche Technologies cloud platform.

## What This Deploys

- **S3 bucket** — static website hosting for the Cheche M-Pesa converter app
- **Budget alarm** — $5/month cost guardrail with email alerts
- **CloudFront CDN** — coming soon
- **Route53 DNS** — coming soon (chechetech.co.ke)
- **AWS Cognito** — coming soon (user authentication)
- **DynamoDB** — coming soon (usage tracking)

## Tech Stack

- Terraform v1.15.6
- AWS Provider ~> 5.0
- Region: us-east-1

## Prerequisites

- AWS CLI configured (`aws configure`)
- Terraform >= 1.0 installed

## Usage

```bash
terraform init
terraform plan
terraform apply
```

## Author

**Fredrick Munyao Wambua**  
AWS Certified Solutions Architect – Associate (Score: 810, June 2026)  
Founder, Cheche Technologies | chechetech.co.ke