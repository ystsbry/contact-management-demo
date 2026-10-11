provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      Stack     = "bootstrap"
      ManagedBy = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  state_bucket_name = coalesce(var.state_bucket_name, "${var.project}-tfstate-${local.account_id}")

  # bootstrap が作るロール。deploy ロールに与える `<project>-*` の IAM 権限から除外する。
  bootstrap_role_prefix = "${var.project}-github-"
  deploy_role_name      = "${local.bootstrap_role_prefix}deploy"
  plan_role_name        = "${local.bootstrap_role_prefix}plan"

  envs_state_key_prefix = "envs/"
}
