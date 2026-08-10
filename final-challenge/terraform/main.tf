terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote state — create this S3 bucket ONCE manually before terraform init
  # aws s3 mb s3://abhi-ejaz-terraform-state --region eu-north-1
  backend "s3" {
    bucket         = "abhi-ejaz-terraform-state-v2"
    key            = "prod/terraform.tfstate"
    region         = "eu-north-1"
    encrypt        = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "abhi-ejaz-shop"
      Environment = var.env
      ManagedBy   = "terraform"
    }
  }
}

# ── Data sources ───────────────────────────────────────────
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}
