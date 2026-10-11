output "deploy_role_arn" {
  description = "GitHub Environment（dev / prod）の変数 AWS_DEPLOY_ROLE_ARN に設定する"
  value       = aws_iam_role.deploy.arn
}

output "plan_role_arn" {
  description = "GitHub のリポジトリ変数 AWS_PLAN_ROLE_ARN に設定する"
  value       = aws_iam_role.plan.arn
}

output "state_bucket_name" {
  description = "Terraform state 用 S3 バケット名"
  value       = aws_s3_bucket.state.bucket
}

output "github_oidc_provider_arn" {
  description = "GitHub OIDC プロバイダの ARN"
  value       = local.github_oidc_provider_arn
}

output "backend_config_examples" {
  description = "infra/envs/<env>/backend.tf に書く backend ブロックの例"
  value = {
    for env in var.deploy_environments : env => <<-EOT
      terraform {
        backend "s3" {
          bucket       = "${aws_s3_bucket.state.bucket}"
          key          = "${local.envs_state_key_prefix}${env}/terraform.tfstate"
          region       = "${var.region}"
          use_lockfile = true
          encrypt      = true
        }
      }
    EOT
  }
}
