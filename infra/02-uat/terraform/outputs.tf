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
  description = "Public UAT hostname (Ingress / ACM / Route53 record)"
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

output "alb_dns_name" {
  description = "Public DNS name of the UAT ALB (what uat_fqdn aliases to)."
  value       = aws_lb.uat.dns_name
}

output "alb_zone_id" {
  description = "Canonical hosted zone ID for the ALB."
  value       = aws_lb.uat.zone_id
}

output "acm_certificate_arn" {
  description = "ACM certificate ARN used by the ALB HTTPS listener."
  value       = aws_acm_certificate.uat.arn
}

output "ingress_target_group_name" {
  description = "Target group name the ALB forwards to (ingress-controller NodePort, Traefik or Kong)."
  value       = aws_lb_target_group.ingress.name
}

# Backward-compat alias — old name kept so existing scripts/docs keep working.
output "traefik_target_group_name" {
  description = "Deprecated alias for ingress_target_group_name."
  value       = aws_lb_target_group.ingress.name
}

output "ingress_http_nodeport" {
  description = "NodePort the in-cluster ingress controller (Traefik or Kong) HTTP entrypoint must bind to. install.sh passes this to the Helm release."
  value       = var.ingress_http_nodeport
}

# Backward-compat alias — old name kept so existing install.sh / scripts keep
# working through the rename.
output "traefik_http_nodeport" {
  description = "Deprecated alias for ingress_http_nodeport."
  value       = var.ingress_http_nodeport
}

output "ingress_controller" {
  description = "Which ingress controller install.sh should install (\"traefik\" or \"kong\"). Argo CD ApplicationSet propagates this as ingress.className on app charts."
  value       = var.ingress_controller
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
