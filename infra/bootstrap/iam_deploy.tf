# deploy ロール: main マージ / workflow_dispatch のデプロイで terraform apply と SPA の配置を行う。
# GitHub Environment（dev / prod）に紐づくジョブからのみ引き受けられる。

data "aws_iam_policy_document" "deploy_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:sub"
      values   = [for env in var.deploy_environments : "repo:${var.github_repository}:environment:${env}"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = local.deploy_role_name
  description          = "GitHub Actions (${var.github_repository}) deploy role"
  assume_role_policy   = data.aws_iam_policy_document.deploy_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "deploy_power_user" {
  role       = aws_iam_role.deploy.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/PowerUserAccess"
}

# PowerUserAccess は IAM をほぼ操作できないため、アプリが使う `<project>-*` のロールと
# ポリシーに限って操作と PassRole を許可する。bootstrap が作るロール自身は明示的に拒否し、
# deploy ロールが自分の権限を広げられないようにする。
data "aws_iam_policy_document" "deploy_iam" {
  statement {
    sid = "ManageProjectRoles"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:ListRoleTags",
      "iam:PutRolePolicy",
      "iam:GetRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:ListRolePolicies",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
    ]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/${var.project}-*"]
  }

  statement {
    sid = "ManageProjectPolicies"
    actions = [
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:GetPolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions",
      "iam:SetDefaultPolicyVersion",
      "iam:TagPolicy",
      "iam:UntagPolicy",
      "iam:ListPolicyTags",
      "iam:ListEntitiesForPolicy",
    ]
    resources = ["arn:${local.partition}:iam::${local.account_id}:policy/${var.project}-*"]
  }

  statement {
    sid       = "PassProjectRoles"
    actions   = ["iam:PassRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/${var.project}-*"]
  }

  # AWS 管理ポリシーの参照や、refresh 時のロール・ポリシーの読み取りに使う。
  statement {
    sid = "ReadIam"
    actions = [
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicies",
      "iam:ListRoles",
    ]
    resources = ["*"]
  }

  statement {
    sid     = "DenyBootstrapRoles"
    effect  = "Deny"
    actions = ["iam:*"]
    resources = [
      "arn:${local.partition}:iam::${local.account_id}:role/${local.bootstrap_role_prefix}*",
    ]
  }
}

resource "aws_iam_role_policy" "deploy_iam" {
  name   = "${var.project}-project-iam"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy_iam.json
}
