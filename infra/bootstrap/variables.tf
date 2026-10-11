variable "region" {
  description = "state バケットと IAM を管理するリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "project" {
  description = "リソース名のプレフィックス"
  type        = string
  default     = "contact"
}

variable "github_repository" {
  description = "OIDC で信頼する GitHub リポジトリ（owner/name）"
  type        = string
  default     = "ystsbry/contact-management-demo"
}

variable "deploy_environments" {
  description = "deploy ロールを引き受けられる GitHub Environment 名"
  type        = list(string)
  default     = ["dev", "prod"]
}

variable "create_oidc_provider" {
  description = "GitHub の OIDC プロバイダを作成するか。アカウントに既に存在する場合は false にして既存を参照する"
  type        = bool
  default     = true
}

variable "state_bucket_name" {
  description = "Terraform state 用 S3 バケット名。null の場合は <project>-tfstate-<アカウント ID>"
  type        = string
  default     = null
}

variable "state_noncurrent_version_retention_days" {
  description = "state バケットで旧バージョンを保持する日数"
  type        = number
  default     = 90
}
