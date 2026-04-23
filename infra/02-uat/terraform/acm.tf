# ACM certificate for uat_fqdn, DNS-validated via the Route53 child zone.
# Prerequisite: the child zone NS records are delegated from Cloudflare
# (see route53_child_zone_name_servers output) — otherwise validation hangs.
resource "aws_acm_certificate" "uat" {
  domain_name       = var.uat_fqdn
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = var.tags
}

resource "aws_route53_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.uat.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  zone_id         = aws_route53_zone.child.zone_id
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
}

resource "aws_acm_certificate_validation" "uat" {
  certificate_arn         = aws_acm_certificate.uat.arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]
}
