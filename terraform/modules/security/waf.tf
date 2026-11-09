###############################################################################
# Regional WAFv2 web ACL for the ingestion ALB.
#   1. Per-IP rate limit: 1,000 requests / 5-minute window (block, 429).
#   2. AWS IP reputation list.
#   3. Known bad inputs (Log4j, etc.).
#   4. Core rule set (with SizeRestrictions_BODY counted, since signed webhook
#      batches can legitimately exceed 8 KB; the app enforces its own limit).
###############################################################################

resource "aws_wafv2_web_acl" "this" {
  name        = "${var.name}-ingress"
  description = "AetherPay webhook ingress protection"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  custom_response_body {
    key          = "rate-limited"
    content_type = "APPLICATION_JSON"
    content      = jsonencode({ error = "rate_limited", retry_after_seconds = var.waf_rate_window_seconds })
  }

  rule {
    name     = "per-ip-rate-limit"
    priority = 0

    action {
      block {
        custom_response {
          response_code            = 429
          custom_response_body_key = "rate-limited"

          response_header {
            name  = "Retry-After"
            value = tostring(var.waf_rate_window_seconds)
          }
        }
      }
    }

    statement {
      rate_based_statement {
        limit                 = var.waf_rate_limit
        evaluation_window_sec = var.waf_rate_window_seconds
        aggregate_key_type    = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-ip-reputation"
    priority = 10

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesAmazonIpReputationList"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-ip-reputation"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-known-bad-inputs"
    priority = 20

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-common"
    priority = 30

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"

        rule_action_override {
          name = "SizeRestrictions_BODY"
          action_to_use {
            count {}
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-common"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-ingress"
    sampled_requests_enabled   = true
  }

  tags = local.tags
}

# WAF log group names must start with "aws-waf-logs-".
resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-${var.name}"
  retention_in_days = var.waf_log_retention_days
  kms_key_id        = aws_kms_key.this["logs"].arn
  tags              = local.tags
}

resource "aws_wafv2_web_acl_logging_configuration" "this" {
  resource_arn            = aws_wafv2_web_acl.this.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]

  # Never log signature material or bearer tokens.
  redacted_fields {
    single_header {
      name = "authorization"
    }
  }

  redacted_fields {
    single_header {
      name = "x-aetherpay-signature"
    }
  }
}
