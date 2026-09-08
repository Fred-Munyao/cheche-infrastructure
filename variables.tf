# ──────────────────────────────────────────────
# Variables — Cheche Technologies Infrastructure
# ──────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "owner" {
  description = "Owner of the infrastructure"
  type        = string
  default     = "Fredrick Wambua, Cheche Technologies"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "prod"
}

# ── Daraja / M-Pesa ──
# No defaults on purpose: values come from terraform.tfvars (gitignored) or TF_VAR_* env vars.
# A missing value fails at plan time rather than shipping blank credentials to the Lambda.

variable "daraja_consumer_key" {
  description = "Daraja API Consumer Key"
  type        = string
  sensitive   = true
}

variable "daraja_consumer_secret" {
  description = "Daraja API Consumer Secret"
  type        = string
  sensitive   = true
}

variable "daraja_shortcode" {
  description = "M-Pesa Paybill shortcode (sandbox: 174379)"
  type        = string
}

variable "daraja_passkey" {
  description = "Daraja Lipa Na M-Pesa passkey"
  type        = string
  sensitive   = true
}

variable "daraja_env" {
  description = "Daraja environment: sandbox or production"
  type        = string
  default     = "production"

  validation {
    condition     = contains(["sandbox", "production"], var.daraja_env)
    error_message = "daraja_env must be \"sandbox\" or \"production\"."
  }
}
