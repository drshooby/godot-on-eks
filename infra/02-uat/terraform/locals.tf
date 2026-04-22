locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name

  # uat_fqdn must end with .<route53_child_zone_name> so the record lives in the child zone.
  uat_record_name = replace(var.uat_fqdn, ".${var.route53_child_zone_name}", "")

  create_uat_alias = var.uat_gateway_lb_dns_name != "" && var.uat_gateway_lb_hosted_zone_id != ""
}
