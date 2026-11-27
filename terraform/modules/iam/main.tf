# Роль исполнения Lambda по принципу наименьших привилегий:
# только своя таблица, только префикс generations/ своего бакета,
# только один параметр SSM с ключом Gemini.

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  # "/fct-adgen/gemini-api-key" -> "arn:aws:ssm:<region>:<acc>:parameter/fct-adgen/gemini-api-key"
  gemini_param_arn = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/${trimprefix(var.gemini_param_name, "/")}"
}

resource "aws_iam_role" "lambda" {
  name = "${var.name}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Логи CloudWatch + (если Lambda в VPC) создание сетевых интерфейсов
resource "aws_iam_role_policy_attachment" "basic" {
  role = aws_iam_role.lambda.name
  policy_arn = (var.in_vpc
    ? "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
    : "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  )
}

resource "aws_iam_role_policy" "app" {
  name = "${var.name}-lambda-app"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "HistoryTable"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query"
        ]
        Resource = [var.table_arn, "${var.table_arn}/index/*"]
      },
      {
        Sid      = "GenerationArchive"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "${var.artifacts_bucket_arn}/generations/*"
      },
      {
        Sid      = "GeminiKey"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = local.gemini_param_arn
      },
      {
        # SecureString зашифрован ключом aws/ssm; расшифровка только через SSM
        Sid      = "DecryptViaSsm"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = "*"
        Condition = {
          StringEquals = { "kms:ViaService" = "ssm.${data.aws_region.current.region}.amazonaws.com" }
        }
      }
    ]
  })
}
