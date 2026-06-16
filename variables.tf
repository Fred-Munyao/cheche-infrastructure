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
# Store sensitive values in terraform.tfvars (gitignored) or AWS Secrets Manager

variable "daraja_consumer_key" {
  description = "Daraja API Consumer Key"
  type        = string
  sensitive   = true
  default     = ""
}

variable "daraja_consumer_secret" {
  description = "Daraja API Consumer Secret"
  type        = string
  sensitive   = true
  default     = ""
}

variable "daraja_shortcode" {
  description = "M-Pesa Paybill shortcode"
  type        = string
  default     = "174379" # sandbox default
}

variable "daraja_passkey" {
  description = "Daraja Lipa Na M-Pesa passkey"
  type        = string
  sensitive   = true
  default     = ""
}

variable "daraja_env" {
  description = "Daraja environment: sandbox or production"
  type        = string
  default     = "sandbox"
}
