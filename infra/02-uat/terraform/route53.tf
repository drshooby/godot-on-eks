resource "aws_route53_zone" "child" {
  name    = var.route53_child_zone_name
  comment = "UAT child zone — delegate from Cloudflare (ettukube.com) using name_servers output"

  tags = var.tags
}

# Alias uat_fqdn directly at the Terraform-managed ALB. No post-apply variable
# dance is needed: both the zone and the ALB exist in this module.
resource "aws_route53_record" "uat_alias" {
  zone_id = aws_route53_zone.child.zone_id
  name    = local.uat_record_name
  type    = "A"

  alias {
    name                   = aws_lb.uat.dns_name
    zone_id                = aws_lb.uat.zone_id
    evaluate_target_health = true
  }
}
