terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # 初回はローカル state で apply する（state バケット自体をここで作るため）。
  # apply 後に state をバケットへ移す場合は、bucket を outputs の state_bucket_name に
  # 置き換えてコメントを外し、`terraform init -migrate-state` を実行する（README 参照）。
  #
  # backend "s3" {
  #   bucket       = "contact-tfstate-<ACCOUNT_ID>"
  #   key          = "bootstrap/terraform.tfstate"
  #   region       = "ap-northeast-1"
  #   use_lockfile = true
  #   encrypt      = true
  # }
}
