# Модуль создаёт три ролевые группы и IAM-пользователей команды.
# Ключи доступа и пароли Terraform НЕ создаёт: иначе они оказались бы в state.
# Пароль для консоли задаёт владелец аккаунта (см. docs/OWNER_CHECKLIST.md),
# ключи доступа каждый участник создаёт себе сам после входа.

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  roles      = toset(["backend", "frontend", "qa"])
  # Все ресурсы приложения начинаются с этого префикса
  app_prefix = var.project
}

# ---------------------------------------------------------------------------
# Группы
# ---------------------------------------------------------------------------
resource "aws_iam_group" "role" {
  for_each = local.roles
  name     = "${var.project}-${each.key}"
}

resource "aws_iam_user" "member" {
  for_each      = var.members
  name          = each.key
  force_destroy = true # чтобы destroy удалял и ключи, и пароль пользователя

  tags = {
    Role = each.value
  }
}

resource "aws_iam_user_group_membership" "member" {
  for_each = var.members
  user     = aws_iam_user.member[each.key].name
  groups   = [aws_iam_group.role[each.value].name]
}

# ---------------------------------------------------------------------------
# Общие политики для всех групп
# ---------------------------------------------------------------------------

# Самообслуживание: сменить свой пароль, завести свои ключи и MFA
resource "aws_iam_policy" "self_service" {
  name        = "${var.project}-self-service"
  description = "Управление только своими учётными данными"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "OwnCredentials"
        Effect = "Allow"
        Action = [
          "iam:GetUser",
          "iam:ChangePassword",
          "iam:CreateAccessKey",
          "iam:DeleteAccessKey",
          "iam:ListAccessKeys",
          "iam:UpdateAccessKey",
          "iam:GetAccessKeyLastUsed",
          "iam:GetLoginProfile",
          "iam:ListMFADevices",
          "iam:EnableMFADevice",
          "iam:ResyncMFADevice",
          "iam:DeactivateMFADevice"
        ]
        Resource = "arn:aws:iam::${local.account_id}:user/$${aws:username}"
      },
      {
        Sid    = "OwnVirtualMFA"
        Effect = "Allow"
        Action = [
          "iam:CreateVirtualMFADevice",
          "iam:DeleteVirtualMFADevice"
        ]
        Resource = "arn:aws:iam::${local.account_id}:mfa/*"
      },
      {
        Sid      = "ReadPasswordPolicy"
        Effect   = "Allow"
        Action   = ["iam:GetAccountPasswordPolicy", "iam:ListVirtualMFADevices"]
        Resource = "*"
      }
    ]
  })
}

# Ограничители: явный Deny сильнее любого Allow, в том числе ReadOnlyAccess
resource "aws_iam_policy" "guardrails" {
  name        = "${var.project}-guardrails"
  description = "Запреты для участников команды: секреты, state, удаление ресурсов, EC2"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Ключ Gemini читает только роль Lambda. Без этого запрета
        # ReadOnlyAccess позволил бы прочитать SecureString.
        Sid    = "NoAppSecrets"
        Effect = "Deny"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath",
          "ssm:GetParameterHistory",
          "ssm:PutParameter",
          "ssm:DeleteParameter",
          "ssm:DeleteParameters"
        ]
        Resource = "arn:aws:ssm:*:${local.account_id}:parameter/${var.project}/*"
      },
      {
        Sid      = "NoTerraformState"
        Effect   = "Deny"
        Action   = ["s3:*", "dynamodb:*"]
        Resource = [var.state_bucket_arn, "${var.state_bucket_arn}/*", var.lock_table_arn]
      },
      {
        Sid    = "NoDestructiveActions"
        Effect = "Deny"
        Action = [
          "dynamodb:DeleteTable",
          "s3:DeleteBucket",
          "s3:PutBucketPolicy",
          "s3:PutBucketPublicAccessBlock",
          "lambda:DeleteFunction",
          "cloudfront:DeleteDistribution",
          "cloudfront:UpdateDistribution",
          "apigateway:DELETE",
          "ec2:RunInstances",
          "ec2:TerminateInstances",
          "budgets:ModifyBudget",
          "budgets:DeleteBudgetAction"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_group_policy_attachment" "self_service" {
  for_each   = aws_iam_group.role
  group      = each.value.name
  policy_arn = aws_iam_policy.self_service.arn
}

resource "aws_iam_group_policy_attachment" "guardrails" {
  for_each   = aws_iam_group.role
  group      = each.value.name
  policy_arn = aws_iam_policy.guardrails.arn
}

# ---------------------------------------------------------------------------
# backend: читать логи и метрики, смотреть и обновлять код Lambda, читать историю
# ---------------------------------------------------------------------------
resource "aws_iam_policy" "backend" {
  name = "${var.project}-backend-dev"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AppLambda"
        Effect = "Allow"
        Action = [
          "lambda:UpdateFunctionCode",
          "lambda:InvokeFunction"
        ]
        Resource = "arn:aws:lambda:*:${local.account_id}:function:${local.app_prefix}-*"
      },
      {
        Sid    = "AppTableRead"
        Effect = "Allow"
        Action = [
          "dynamodb:DescribeTable",
          "dynamodb:GetItem",
          "dynamodb:Query",
          "dynamodb:Scan"
        ]
        Resource = [
          "arn:aws:dynamodb:*:${local.account_id}:table/${local.app_prefix}-*",
          "arn:aws:dynamodb:*:${local.account_id}:table/${local.app_prefix}-*/index/*"
        ]
      },
      {
        Sid      = "ListTables"
        Effect   = "Allow"
        Action   = ["dynamodb:ListTables"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_group_policy_attachment" "backend" {
  for_each = {
    custom = aws_iam_policy.backend.arn
    lambda = "arn:aws:iam::aws:policy/AWSLambda_ReadOnlyAccess"
    logs   = "arn:aws:iam::aws:policy/CloudWatchLogsReadOnlyAccess"
    cw     = "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"
  }
  group      = aws_iam_group.role["backend"].name
  policy_arn = each.value
}

# ---------------------------------------------------------------------------
# frontend: заливать файлы сайта и сбрасывать кэш CloudFront
# ---------------------------------------------------------------------------
resource "aws_iam_policy" "frontend" {
  name = "${var.project}-frontend-dev"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListBuckets"
        Effect   = "Allow"
        Action   = ["s3:ListAllMyBuckets", "s3:GetBucketLocation"]
        Resource = "*"
      },
      {
        Sid      = "SiteBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${local.app_prefix}-*-frontend-*"
      },
      {
        Sid      = "SiteObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "arn:aws:s3:::${local.app_prefix}-*-frontend-*/*"
      },
      {
        Sid    = "CloudFrontCache"
        Effect = "Allow"
        Action = [
          "cloudfront:ListDistributions",
          "cloudfront:GetDistribution",
          "cloudfront:CreateInvalidation",
          "cloudfront:GetInvalidation",
          "cloudfront:ListInvalidations"
        ]
        Resource = "*"
      },
      {
        Sid      = "SeeApi"
        Effect   = "Allow"
        Action   = ["apigateway:GET"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_group_policy_attachment" "frontend" {
  group      = aws_iam_group.role["frontend"].name
  policy_arn = aws_iam_policy.frontend.arn
}

# ---------------------------------------------------------------------------
# qa (документация и тестирование): только чтение всего аккаунта
# ---------------------------------------------------------------------------
resource "aws_iam_group_policy_attachment" "qa" {
  group      = aws_iam_group.role["qa"].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}
