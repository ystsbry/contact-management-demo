locals {
  github_oidc_url  = "https://token.actions.githubusercontent.com"
  github_oidc_host = trimprefix(local.github_oidc_url, "https://")

  github_oidc_provider_arn = (
    var.create_oidc_provider
    ? aws_iam_openid_connect_provider.github[0].arn
    : data.aws_iam_openid_connect_provider.github[0].arn
  )
}

# GitHub の OIDC はルート CA で検証されるため thumbprint_list は指定しない。
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url            = local.github_oidc_url
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1

  url = local.github_oidc_url
}
