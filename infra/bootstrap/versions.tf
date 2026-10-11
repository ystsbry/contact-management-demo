terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # state はこの bootstrap 自身が作った S3 バケットに置く。
  # 初回（バケット作成前）はこのブロックをコメントアウトしてローカル state で apply し、
  # 作成後に `terraform init -migrate-state` でバケットへ移した（README 参照）。
  backend "s3" {
    bucket       = "contact-tfstate-423563856220"
    key          = "bootstrap/terraform.tfstate"
    region       = "ap-northeast-1"
    use_lockfile = true
    encrypt      = true
  }
}
