###############################################################################
# Public ingress: ALB (TLS 1.3 only) + WAF + ACM + Route 53.
# There is no port-80 listener at all; partners must speak TLS 1.3.
###############################################################################

locals {
  tags            = merge(var.tags, { "aetherpay:module" = "edge" })
  create_cert     = var.certificate_arn == null
  certificate_arn = local.create_cert ? aws_acm_certificate_validation.this[0].certificate_arn : var.certificate_arn
  validation = local.create_cert ? {
    for o in aws_acm_certificate.this[0].domain_validation_options : o.domain_name => o
  } : {}

  # Every name on the certificate, e.g. the regional probe name plus the global
  # partner-facing name that ARC points at this ALB. TLS clients verify the
  # hostname they dialled, so the global name must be on each regional cert.
  cert_names = concat([var.domain_name], var.subject_alternative_names)

  # ACM uses the same validation CNAME for a name in every region of an account.
  # Only one stack may own the record for a shared SAN, or a destroy in one
  # region would delete the other region's validation record.
  validation_record_names = var.create_san_validation_records ? local.cert_names : [var.domain_name]
}

check "certificate_source" {
  assert {
    condition     = var.certificate_arn != null || var.hosted_zone_id != null
    error_message = "Provide either certificate_arn or hosted_zone_id so the ALB can terminate TLS."
  }
}

# --------------------------------------------------------------- certificate
resource "aws_acm_certificate" "this" {
  count = local.create_cert ? 1 : 0

  domain_name               = var.domain_name
  subject_alternative_names = var.subject_alternative_names
  validation_method         = "DNS"
  key_algorithm             = "EC_prime256v1"
  tags                      = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "validation" {
  # Keyed by the static domain name so the plan never depends on apply-time values.
  for_each = local.create_cert ? toset(local.validation_record_names) : toset([])

  zone_id         = var.hosted_zone_id
  name            = local.validation[each.key].resource_record_name
  type            = local.validation[each.key].resource_record_type
  records         = [local.validation[each.key].resource_record_value]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  count = local.create_cert ? 1 : 0

  certificate_arn = aws_acm_certificate.this[0].arn
  # Built from ACM's own validation names so a SAN whose record is owned by the
  # other region's stack is still waited for.
  validation_record_fqdns = [for n in local.cert_names : trimsuffix(local.validation[n].resource_record_name, ".")]

  depends_on = [aws_route53_record.validation]
}

# ------------------------------------------------------------------------ ALB
resource "aws_lb" "this" {
  name               = substr("${var.name}-ingress", 0, 32)
  load_balancer_type = "application"
  internal           = false
  subnets            = var.public_subnet_ids
  security_groups    = [var.alb_security_group_id]
  ip_address_type    = "ipv4"

  drop_invalid_header_fields = true
  desync_mitigation_mode     = "strictest"
  enable_deletion_protection = var.deletion_protection
  enable_http2               = true
  idle_timeout               = 30
  enable_waf_fail_open       = false

  access_logs {
    bucket  = aws_s3_bucket.logs.id
    prefix  = "alb"
    enabled = true
  }

  connection_logs {
    bucket  = aws_s3_bucket.logs.id
    prefix  = "alb-connections"
    enabled = true
  }

  tags = local.tags

  depends_on = [aws_s3_bucket_policy.logs]
}

resource "aws_lb_target_group" "app" {
  #checkov:skip=CKV_AWS_378:TLS 1.3 terminates at the ALB as specified; the hop to targets stays inside SG-locked private subnets.
  name                 = substr("${var.name}-app", 0, 32)
  vpc_id               = var.vpc_id
  port                 = var.app_port
  protocol             = "HTTP"
  target_type          = "ip"
  deregistration_delay = 30

  health_check {
    path                = var.health_check_path
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = local.tags
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = var.ssl_policy
  certificate_arn   = local.certificate_arn

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "application/json"
      message_body = "{\"error\":\"not_found\"}"
      status_code  = "404"
    }
  }

  tags = local.tags
}

resource "aws_lb_listener_rule" "webhooks" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  condition {
    path_pattern {
      values = ["/webhooks/*", "/healthz"]
    }
  }

  condition {
    http_request_method {
      values = ["POST", "GET"]
    }
  }

  tags = local.tags
}

resource "aws_wafv2_web_acl_association" "this" {
  resource_arn = aws_lb.this.arn
  web_acl_arn  = var.waf_web_acl_arn
}

resource "aws_route53_record" "alias" {
  count = var.hosted_zone_id == null ? 0 : 1

  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}
