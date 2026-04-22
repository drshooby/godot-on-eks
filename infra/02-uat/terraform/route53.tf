resource "aws_route53_zone" "child" {
  name    = var.route53_child_zone_name
  comment = "UAT child zone — delegate from Cloudflare (ettukube.com) using name_servers output"

  tags = var.tags
}

resource "aws_route53_record" "uat_alias" {
  count = local.create_uat_alias ? 1 : 0

  zone_id = aws_route53_zone.child.zone_id
  name    = local.uat_record_name
  type    = "A"

  alias {
    name                   = var.uat_gateway_lb_dns_name
    zone_id                = var.uat_gateway_lb_hosted_zone_id
    evaluate_target_health = true
  }
}
