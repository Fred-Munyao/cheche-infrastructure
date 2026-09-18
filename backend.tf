# Remote state for Cheche — versioned S3 bucket, native lockfile (Terraform >= 1.10)
terraform {
  backend "s3" {
    bucket       = "cheche-tf-state-507629158424"
    key          = "cheche/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
