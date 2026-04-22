# IRSA for External Secrets Operator — read app secrets from Secrets Manager (narrow with app-specific policies later).
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

module "irsa_external_secrets" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.47"

  role_name = "uat-external-secrets"

  role_policy_arns = {
    secrets = aws_iam_policy.external_secrets.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets"]
    }
  }

  tags = var.tags
}
