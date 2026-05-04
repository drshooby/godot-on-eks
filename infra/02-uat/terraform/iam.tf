# IAM for External Secrets Operator — reads app secrets from Secrets Manager under uat/*.
#
# Auth mechanism: **EKS Pod Identity** (see eks-pod-identity-agent addon in eks.tf and the
# aws_eks_pod_identity_association below). The role's trust policy also still allows the
# cluster's OIDC provider (IRSA) so anything lingering on the old mechanism keeps working
# during the migration. Pod Identity takes precedence when both are present, so the
# service account no longer needs the `eks.amazonaws.com/role-arn` annotation and the
# install script no longer has to hand-wire `AWS_WEB_IDENTITY_TOKEN_FILE`.
#
# TODO: once everything is confirmed on Pod Identity, drop the OIDC statement from the
# trust policy and remove the OIDC provider from the EKS module.

data "aws_iam_policy_document" "external_secrets" {
  statement {
    sid = "SecretsManagerRead"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = ["arn:aws:secretsmanager:${local.region}:${local.account_id}:secret:uat/*"]
  }
}

resource "aws_iam_policy" "external_secrets" {
  name        = "uat-external-secrets-read"
  description = "Allow External Secrets in UAT to read Secrets Manager secrets under uat/*"
  policy      = data.aws_iam_policy_document.external_secrets.json

  tags = var.tags
}

data "aws_iam_policy_document" "external_secrets_trust" {
  # EKS Pod Identity — the pod-identity-agent exchanges the pod's service-account
  # credentials for this role. sts:TagSession is required.
  statement {
    sid     = "PodIdentity"
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }

  # IRSA (OIDC) — kept for backward compatibility while migrating. Safe to delete along
  # with the OIDC provider once Pod Identity is verified end-to-end.
  statement {
    sid     = "IRSA"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:external-secrets:external-secrets"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "external_secrets" {
  name               = "uat-external-secrets"
  assume_role_policy = data.aws_iam_policy_document.external_secrets_trust.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "external_secrets" {
  role       = aws_iam_role.external_secrets.name
  policy_arn = aws_iam_policy.external_secrets.arn
}

# Bind the role to the external-secrets/external-secrets service account via Pod Identity.
resource "aws_eks_pod_identity_association" "external_secrets" {
  cluster_name    = module.eks.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.external_secrets.arn

  tags = var.tags
}
