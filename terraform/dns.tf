# DNS: lookup of the existing Route53 zone, plus the optional custom-domain ACM certificate, validation records and CloudFront alias records.

# --- Existing Route53 hosted zone (read-only) ---
#
# uniflow.fabian-vargas.com is registered outside Route53 (Dondominio); only
# this subdomain is delegated to AWS. The public hosted zone already exists
# and is shared across rebuilds of this stack, so it is looked up, never
# created or destroyed here. Lookup is by route53_zone_id when set, otherwise
# by domain_name.

data "aws_route53_zone" "site" {
  count = local.custom_domain ? 1 : 0

  zone_id      = var.route53_zone_id
  name         = var.route53_zone_id == null ? var.domain_name : null
  private_zone = false
}

locals {
  site_zone_id = local.custom_domain ? data.aws_route53_zone.site[0].zone_id : null
}

# --- Custom domain (optional) ---

resource "aws_acm_certificate" "site" {
  count    = local.custom_domain ? 1 : 0
  provider = aws.us_east_1

  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name     = "${var.project-tag}-site"
    projects = var.project-tag
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = local.custom_domain ? {
    for dvo in aws_acm_certificate.site[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  } : {}

  zone_id         = local.site_zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "site" {
  count    = local.custom_domain ? 1 : 0
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.site[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

resource "aws_route53_record" "site" {
  for_each = local.custom_domain ? toset(["A", "AAAA"]) : toset([])

  zone_id = local.site_zone_id
  name    = var.domain_name
  type    = each.key

  alias {
    name                   = aws_cloudfront_distribution.spa.domain_name
    zone_id                = aws_cloudfront_distribution.spa.hosted_zone_id
    evaluate_target_health = false
  }
}
