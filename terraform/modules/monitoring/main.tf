# Мониторинг: SNS-топик для оповещений, алармы CloudWatch и дашборд.
# Всё в бесплатных лимитах: до 10 алармов, до 3 дашбордов, 1000 email от SNS.

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

data "aws_region" "current" {}

locals {
  region     = data.aws_region.current.region
  alarm_arns = [aws_sns_topic.alerts.arn]
}

resource "aws_sns_topic" "alerts" {
  name = "${var.name}-alerts"
}

# Подписку нужно подтвердить по ссылке из письма
resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ---------------------------------------------------------------------------
# Lambda
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${var.name}-lambda-errors"
  alarm_description   = "Необработанные ошибки в функции генератора"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = var.lambda_function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_arns
  ok_actions          = local.alarm_arns
}

resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  alarm_name          = "${var.name}-lambda-throttles"
  alarm_description   = "Lambda упирается в лимит параллельности"
  namespace           = "AWS/Lambda"
  metric_name         = "Throttles"
  dimensions          = { FunctionName = var.lambda_function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_arns
}

resource "aws_cloudwatch_metric_alarm" "lambda_slow" {
  alarm_name          = "${var.name}-lambda-near-timeout"
  alarm_description   = "Ответ дольше 25 с: близко к лимиту API Gateway в 30 с"
  namespace           = "AWS/Lambda"
  metric_name         = "Duration"
  dimensions          = { FunctionName = var.lambda_function_name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 25000
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_arns
}

# ---------------------------------------------------------------------------
# API Gateway
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name          = "${var.name}-api-5xx"
  alarm_description   = "API вернул 5xx (ошибка Lambda, таймаут или сбой Gemini)"
  namespace           = "AWS/ApiGateway"
  metric_name         = "5xx"
  dimensions          = { ApiId = var.api_id }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_arns
  ok_actions          = local.alarm_arns
}

# ---------------------------------------------------------------------------
# Свои метрики из Lambda (Embedded Metric Format в логах)
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "gemini_errors" {
  alarm_name          = "${var.name}-gemini-errors"
  alarm_description   = "Вызовы Gemini завершаются ошибкой: ключ, квота или недоступность"
  namespace           = var.metrics_namespace
  metric_name         = "GeminiErrors"
  dimensions          = { Environment = var.environment }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 2
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_arns
}

# ---------------------------------------------------------------------------
# NAT-инстанс: автовосстановление при сбое железа AWS
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "nat_recover" {
  count               = var.nat_enabled ? 1 : 0
  alarm_name          = "${var.name}-nat-system-check"
  alarm_description   = "Сбой хоста NAT-инстанса: автоматический recover"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  dimensions          = { InstanceId = var.nat_instance_id }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  alarm_actions       = ["arn:aws:automate:${local.region}:ec2:recover", aws_sns_topic.alerts.arn]
}

# ---------------------------------------------------------------------------
# Дашборд
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.name}-overview"

  dashboard_body = jsonencode({
    widgets = concat([
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title  = "API: запросы и ошибки"
          region = local.region
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/ApiGateway", "Count", "ApiId", var.api_id],
            [".", "4xx", ".", "."],
            [".", "5xx", ".", "."]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title  = "API: задержка, мс"
          region = local.region
          period = 300
          metrics = [
            ["AWS/ApiGateway", "Latency", "ApiId", var.api_id, { stat = "p50" }],
            ["...", { stat = "p90" }],
            ["...", { stat = "Maximum" }]
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title  = "Lambda: вызовы, ошибки, троттлинг"
          region = local.region
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", var.lambda_function_name],
            [".", "Errors", ".", "."],
            [".", "Throttles", ".", "."]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title  = "Gemini: время ответа, мс и ошибки"
          region = local.region
          period = 300
          metrics = [
            [var.metrics_namespace, "GeminiLatencyMs", "Environment", var.environment, { stat = "Average" }],
            ["...", { stat = "Maximum" }],
            [var.metrics_namespace, "GeminiErrors", "Environment", var.environment, { stat = "Sum", yAxis = "right" }]
          ]
        }
      },
      {
        type = "metric", x = 0, y = 12, width = 12, height = 6
        properties = {
          title  = "Сгенерировано сценариев"
          region = local.region
          stat   = "Sum"
          period = 3600
          metrics = [
            [var.metrics_namespace, "ScenariosGenerated", "Environment", var.environment]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 12, width = 12, height = 6
        properties = {
          title  = "DynamoDB: потреблённая ёмкость"
          region = local.region
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/DynamoDB", "ConsumedReadCapacityUnits", "TableName", var.table_name],
            [".", "ConsumedWriteCapacityUnits", ".", "."]
          ]
        }
      }
      ],
      var.nat_enabled ? [
        {
          type = "metric", x = 0, y = 18, width = 24, height = 6
          properties = {
            title  = "NAT-инстанс: CPU и трафик"
            region = local.region
            period = 300
            metrics = [
              ["AWS/EC2", "CPUUtilization", "InstanceId", var.nat_instance_id, { stat = "Average" }],
              [".", "NetworkOut", ".", ".", { stat = "Sum", yAxis = "right" }]
            ]
          }
        }
    ] : [])
  })
}
