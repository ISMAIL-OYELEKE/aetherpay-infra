###############################################################################
# Keyless CI: GitHub Actions OIDC federation.
#
#   aetherpay-gha-plan-<env>   read-only + state lock, assumable from pull
#                              requests and from main (drift detection)
#   aetherpay-gha-apply-<env>  deploy rights, assumable ONLY from a job bound
#                              to the GitHub Environment <env>, which carries
#                              required reviewers
###############################################################################

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn

  # GitHub's OIDC "sub" claim starts with this prefix. Repositories using
  # immutable subjects embed the owner and repository IDs
  # (repo:<owner>@<owner_id>/<repo>@<repo_id>), so a deleted-and-recreated or
  # renamed repository with the same name cannot assume these roles.
  oidc_subject_prefix = coalesce(var.github_oidc_subject_prefix, "repo:${var.github_repository}")
}

# ------------------------------------------------------------------ trust
data "aws_iam_policy_document" "plan_trust" {
  for_each = toset(var.environments)

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "${local.oidc_subject_prefix}:pull_request",
        "${local.oidc_subject_prefix}:ref:refs/heads/main",
      ]
    }
  }
}

data "aws_iam_policy_document" "apply_trust" {
  for_each = toset(var.environments)

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.oidc_subject_prefix}:environment:${each.key}"]
    }
  }
}

# ------------------------------------------------------------- state access
data "aws_iam_policy_document" "state_access" {
  for_each = toset(var.environments)

  statement {
    sid       = "ListStateBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${each.key}/*"]
    }
  }

  statement {
    sid       = "ReadWriteOwnEnvironmentState"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/${each.key}/*"]
  }

  statement {
    sid       = "StateKey"
    actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [aws_kms_key.state.arn]
  }
}

# ------------------------------------------------------------------- plan
resource "aws_iam_role" "plan" {
  for_each = toset(var.environments)

  name                 = "aetherpay-gha-plan-${each.key}"
  assume_role_policy   = data.aws_iam_policy_document.plan_trust[each.key].json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  for_each = toset(var.environments)

  role       = aws_iam_role.plan[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "plan_guardrails" {
  statement {
    sid    = "NeverReadSecretMaterial"
    effect = "Deny"
    actions = [
      "secretsmanager:GetSecretValue",
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "plan_state" {
  for_each = toset(var.environments)

  name   = "terraform-state"
  role   = aws_iam_role.plan[each.key].id
  policy = data.aws_iam_policy_document.state_access[each.key].json
}

resource "aws_iam_role_policy" "plan_guardrails" {
  for_each = toset(var.environments)

  name   = "guardrails"
  role   = aws_iam_role.plan[each.key].id
  policy = data.aws_iam_policy_document.plan_guardrails.json
}

# ------------------------------------------------------------------ apply
resource "aws_iam_role" "apply" {
  for_each = toset(var.environments)

  name                 = "aetherpay-gha-apply-${each.key}"
  assume_role_policy   = data.aws_iam_policy_document.apply_trust[each.key].json
  max_session_duration = 7200 # Aurora + ElastiCache creation can take > 1 h end to end
}

resource "aws_iam_role_policy_attachment" "apply_poweruser" {
  for_each = toset(var.environments)

  role       = aws_iam_role.apply[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

resource "aws_iam_role_policy" "apply_state" {
  for_each = toset(var.environments)

  name   = "terraform-state"
  role   = aws_iam_role.apply[each.key].id
  policy = data.aws_iam_policy_document.state_access[each.key].json
}

# PowerUserAccess excludes IAM. Grant only the IAM needed to manage workload
# roles, and force every role it creates to carry the workload boundary, so
# the pipeline can never mint an unbounded admin role.
data "aws_iam_policy_document" "apply_iam" {
  statement {
    sid = "ManageBoundedWorkloadRoles"
    actions = [
      "iam:CreateRole",
      "iam:PutRolePolicy",
      "iam:AttachRolePolicy",
      "iam:PutRolePermissionsBoundary",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/aetherpay-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [aws_iam_policy.workload_boundary.arn]
    }
  }

  statement {
    sid = "MaintainWorkloadRoles"
    actions = [
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:ListRolePolicies",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/aetherpay-*"]
  }

  statement {
    sid       = "PassWorkloadRolesToServices"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/aetherpay-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values = [
        "ecs-tasks.amazonaws.com",
        "lambda.amazonaws.com",
        "monitoring.rds.amazonaws.com",
        "vpc-flow-logs.amazonaws.com",
      ]
    }
  }

  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/aws-service-role/*"]
  }

  statement {
    sid       = "ReadIam"
    actions   = ["iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicyVersions", "iam:GetOpenIDConnectProvider"]
    resources = ["*"]
  }

  statement {
    sid    = "CannotTouchCiOrBoundary"
    effect = "Deny"
    actions = [
      "iam:CreatePolicyVersion",
      "iam:DeletePolicy",
      "iam:DeleteRolePermissionsBoundary",
      "iam:SetDefaultPolicyVersion",
    ]
    resources = [aws_iam_policy.workload_boundary.arn, "arn:aws:iam::${local.account_id}:role/aetherpay-*"]
  }

  statement {
    sid       = "CannotModifyCiRoles"
    effect    = "Deny"
    actions   = ["iam:*"]
    resources = ["arn:aws:iam::${local.account_id}:role/aetherpay-gha-*"]
  }
}

resource "aws_iam_role_policy" "apply_iam" {
  for_each = toset(var.environments)

  name   = "bounded-iam"
  role   = aws_iam_role.apply[each.key].id
  policy = data.aws_iam_policy_document.apply_iam.json
}
