output "cluster_name" {
  description = "EKS cluster name for kubectl / Argo"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 cluster CA (for kubeconfig)"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "configure_kubectl" {
  description = "One-liner to merge kubeconfig for this cluster"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "uat_fqdn" {
  description = "Public UAT hostname (Helm / cert-manager / HTTPRoute)"
  value       = var.uat_fqdn
}

output "route53_child_zone_id" {
  description = "Hosted zone ID for the delegated child zone"
  value       = aws_route53_zone.child.zone_id
}

output "route53_child_zone_name" {
  value = var.route53_child_zone_name
}

output "route53_child_zone_name_servers" {
  description = "Paste these NS records at Cloudflare for the label that matches route53_child_zone_name (e.g. shmup → this zone)."
  value       = aws_route53_zone.child.name_servers
}

output "uat_alias_record_created" {
  description = "Whether the A/ALIAS for uat_fqdn was created (requires gateway LB variables)."
  value       = local.create_uat_alias
}

output "rds_endpoint" {
  description = "MySQL hostname for app charts (in-cluster or via security groups)"
  value       = module.db.db_instance_address
}


output "external_secrets_irsa_role_arn" {
  description = "Annotate the external-secrets service account with eks.amazonaws.com/role-arn"
  value       = module.irsa_external_secrets.iam_role_arn
}

output "aws_account_id" {
  value = local.account_id
}

output "aws_region" {
  value = local.region
}

output "ecr_image_prefix" {
  description = "Default ECR pull URL prefix for this account/region"
  value       = "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com"
}

output "acme_email" {
  description = "Copy into infra/02-uat/helm/platform values acme.email (Let's Encrypt registration)."
  value       = var.acme_email
}
