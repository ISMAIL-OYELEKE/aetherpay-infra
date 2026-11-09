###############################################################################
# Cross-region failover that does not depend on the failing region's control
# plane.
#
# Route 53 Application Recovery Controller (ARC) routing controls are flipped
# through a 5-region cluster data plane (any 3 endpoints form a quorum), and
# Route 53 health checks / DNS answers are served by the global Route 53 data
# plane. No API call in the impaired region is needed to move traffic.
#
# Safety rule: at least one region must stay "On", so an operator (or a buggy
# script) can never black-hole all traffic.
###############################################################################

variable "name" {
  description = "Name prefix, e.g. aetherpay-production."
  type        = string
}

variable "hosted_zone_id" {
  description = "Public hosted zone for the webhook record."
  type        = string
}

variable "domain_name" {
  description = "Global webhook FQDN, e.g. webhooks.example.com."
  type        = string
}

variable "regions" {
  description = "Regional ALB targets keyed by role. Exactly one primary and one secondary."
  type = map(object({
    region       = string
    alb_dns_name = string
    alb_zone_id  = string
  }))

  validation {
    condition     = toset(keys(var.regions)) == toset(["primary", "secondary"])
    error_message = "regions must have exactly the keys primary and secondary."
  }
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}

resource "aws_route53recoverycontrolconfig_cluster" "this" {
  name = "${var.name}-arc"
}

resource "aws_route53recoverycontrolconfig_control_panel" "this" {
  name        = "${var.name}-traffic"
  cluster_arn = aws_route53recoverycontrolconfig_cluster.this.arn
}

resource "aws_route53recoverycontrolconfig_routing_control" "region" {
  for_each = var.regions

  name              = "${var.name}-${each.key}-${each.value.region}"
  cluster_arn       = aws_route53recoverycontrolconfig_cluster.this.arn
  control_panel_arn = aws_route53recoverycontrolconfig_control_panel.this.arn
}

resource "aws_route53recoverycontrolconfig_safety_rule" "min_one_region" {
  name              = "${var.name}-at-least-one-region-on"
  control_panel_arn = aws_route53recoverycontrolconfig_control_panel.this.arn
  wait_period_ms    = 5000

  asserted_controls = [for rc in aws_route53recoverycontrolconfig_routing_control.region : rc.arn]

  rule_config {
    inverted  = false
    threshold = 1
    type      = "ATLEAST"
  }
}

resource "aws_route53_health_check" "routing_control" {
  for_each = var.regions

  type                = "RECOVERY_CONTROL"
  routing_control_arn = aws_route53recoverycontrolconfig_routing_control.region[each.key].arn
  tags                = merge(var.tags, { Name = "${var.name}-${each.key}-routing-control" })
}

resource "aws_route53_record" "failover" {
  for_each = var.regions

  zone_id         = var.hosted_zone_id
  name            = var.domain_name
  type            = "A"
  set_identifier  = each.key
  health_check_id = aws_route53_health_check.routing_control[each.key].id

  failover_routing_policy {
    type = upper(each.key)
  }

  alias {
    name                   = each.value.alb_dns_name
    zone_id                = each.value.alb_zone_id
    evaluate_target_health = false # the routing control is the single source of truth
  }
}

output "cluster_endpoints" {
  description = "ARC data-plane endpoints. Store these offline in the runbook; they are needed when consoles are down."
  value       = aws_route53recoverycontrolconfig_cluster.this.cluster_endpoints
}

output "routing_control_arns" {
  description = "Routing control ARNs by role."
  value       = { for k, v in aws_route53recoverycontrolconfig_routing_control.region : k => v.arn }
}
