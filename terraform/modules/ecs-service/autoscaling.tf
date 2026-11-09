###############################################################################
# Application Auto Scaling with asymmetric stabilisation.
#
#   Signal                         Scale-out          Scale-in
#   CPU target tracking            60 s cooldown      600 s cooldown
#   Memory target tracking         60 s cooldown      600 s cooldown
#   Queue backlog per task (TT)    30 s cooldown      600 s cooldown
#   Oldest-message age (step)      +100% / 60 s       never (TT handles it)
#   ALB requests per target (TT)   60 s cooldown      600 s cooldown
#
# With several target-tracking policies, ECS scales out when ANY policy asks
# and scales in only when ALL agree, which together with the long scale-in
# cooldown prevents thrashing during bursty payment traffic.
###############################################################################

resource "aws_appautoscaling_target" "this" {
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = "service/${var.cluster_name}/${aws_ecs_service.this.name}"
  min_capacity       = var.min_capacity
  max_capacity       = var.max_capacity
  tags               = local.tags
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.name}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this.service_namespace
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension
  resource_id        = aws_appautoscaling_target.this.resource_id

  target_tracking_scaling_policy_configuration {
    target_value       = var.cpu_target_percent
    scale_out_cooldown = var.scale_out_cooldown_seconds
    scale_in_cooldown  = var.scale_in_cooldown_seconds

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

resource "aws_appautoscaling_policy" "memory" {
  name               = "${var.name}-memory"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this.service_namespace
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension
  resource_id        = aws_appautoscaling_target.this.resource_id

  target_tracking_scaling_policy_configuration {
    target_value       = var.memory_target_percent
    scale_out_cooldown = var.scale_out_cooldown_seconds
    scale_in_cooldown  = var.scale_in_cooldown_seconds

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
  }
}

# Backlog per task = visible messages / running tasks (metric math).
resource "aws_appautoscaling_policy" "queue_backlog" {
  count = var.queue_scaling == null ? 0 : 1

  name               = "${var.name}-queue-backlog"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this.service_namespace
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension
  resource_id        = aws_appautoscaling_target.this.resource_id

  target_tracking_scaling_policy_configuration {
    target_value       = var.queue_scaling.backlog_per_task_target
    scale_out_cooldown = 30
    scale_in_cooldown  = var.scale_in_cooldown_seconds

    customized_metric_specification {
      metrics {
        id          = "visible"
        label       = "Visible messages"
        return_data = false

        metric_stat {
          stat = "Sum"

          metric {
            namespace   = "AWS/SQS"
            metric_name = "ApproximateNumberOfMessagesVisible"

            dimensions {
              name  = "QueueName"
              value = var.queue_scaling.queue_name
            }
          }
        }
      }

      metrics {
        id          = "tasks"
        label       = "Running tasks"
        return_data = false

        metric_stat {
          stat = "Average"

          metric {
            namespace   = "ECS/ContainerInsights"
            metric_name = "RunningTaskCount"

            dimensions {
              name  = "ClusterName"
              value = var.cluster_name
            }

            dimensions {
              name  = "ServiceName"
              value = aws_ecs_service.this.name
            }
          }
        }
      }

      metrics {
        id          = "backlog_per_task"
        label       = "Backlog per task"
        expression  = "IF(tasks > 0, visible / tasks, visible)"
        return_data = true
      }
    }
  }
}

# Burst guard: if the oldest message is getting old, double capacity now
# rather than waiting for target tracking to converge.
resource "aws_appautoscaling_policy" "queue_burst" {
  count = var.queue_scaling == null ? 0 : 1

  name               = "${var.name}-queue-burst"
  policy_type        = "StepScaling"
  service_namespace  = aws_appautoscaling_target.this.service_namespace
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension
  resource_id        = aws_appautoscaling_target.this.resource_id

  step_scaling_policy_configuration {
    adjustment_type          = "PercentChangeInCapacity"
    cooldown                 = 60
    metric_aggregation_type  = "Maximum"
    min_adjustment_magnitude = 2

    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment          = 100
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "queue_burst" {
  count = var.queue_scaling == null ? 0 : 1

  alarm_name          = "${var.name}-queue-oldest-message-age"
  alarm_description   = "Oldest ingestion message older than ${var.queue_scaling.burst_age_seconds}s: step scale-out"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = var.queue_scaling.burst_age_seconds
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = var.queue_scaling.queue_name
  }

  alarm_actions = compact([aws_appautoscaling_policy.queue_burst[0].arn, var.alarm_topic_arn])
  tags          = local.tags
}

resource "aws_appautoscaling_policy" "alb_requests" {
  count = var.alb_request_scaling == null ? 0 : 1

  name               = "${var.name}-alb-requests"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this.service_namespace
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension
  resource_id        = aws_appautoscaling_target.this.resource_id

  target_tracking_scaling_policy_configuration {
    target_value       = var.alb_request_scaling.requests_per_target
    scale_out_cooldown = var.scale_out_cooldown_seconds
    scale_in_cooldown  = var.scale_in_cooldown_seconds

    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = var.alb_request_scaling.resource_label
    }
  }
}
