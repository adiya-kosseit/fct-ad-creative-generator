# Lambda с бэкендом генератора. Код на Python без внешних зависимостей
# (boto3 уже есть в рантайме, Gemini вызывается через urllib), поэтому
# сборка — это просто zip папки src/backend.

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
    archive = {
      source = "hashicorp/archive"
    }
  }
}

data "archive_file" "code" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${path.root}/.build/${var.name}.zip"
  excludes    = ["__pycache__", "**/__pycache__/**", "**/*.pyc", ".pytest_cache"]
}

# Лог-группа создаётся заранее, чтобы задать срок хранения
# и чтобы destroy удалял её вместе с функцией
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.name}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "this" {
  function_name    = var.name
  description      = "Ad creative script generator API (Gemini)"
  role             = var.role_arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.code.output_path
  source_code_hash = data.archive_file.code.output_base64sha256
  memory_size      = var.memory_mb
  # API Gateway HTTP API ждёт не дольше 30 с, функция должна успеть ответить раньше
  timeout = var.timeout_seconds

  environment {
    variables = var.environment
  }

  dynamic "vpc_config" {
    for_each = length(var.subnet_ids) > 0 ? [1] : []
    content {
      subnet_ids         = var.subnet_ids
      security_group_ids = var.security_group_ids
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.lambda.name
  }

  depends_on = [aws_cloudwatch_log_group.lambda]
}
