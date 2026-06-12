variable "project" {
  description = "Project name — used to name all resources"
  type        = string
  default     = "cheche"
}

variable "environment" {
  description = "Environment — dev or prod"
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "owner" {
  description = "Owner of this infrastructure"
  type        = string
  default     = "Fredrick Wambua — Cheche Technologies"
}