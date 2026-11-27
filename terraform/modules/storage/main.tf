# Хранилище приложения:
#   * DynamoDB — история запросов и сценарии (то, что показывает вкладка «История»)
#   * S3       — полный архив каждой генерации: бриф + ответ модели в JSON

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# DynamoDB
# ---------------------------------------------------------------------------
# Ключ: requestId. Для ленты истории «новые сверху» нужен GSI byCreatedAt
# с постоянным ключом раздела pk = "REQ" и сортировкой по createdAt.
# PROVISIONED 5/5 + 5/5 укладывается в бесплатные 25 RCU / 25 WCU.
resource "aws_dynamodb_table" "history" {
  name           = "${var.name}-history"
  billing_mode   = "PROVISIONED"
  read_capacity  = 5
  write_capacity = 5
  hash_key       = "requestId"

  attribute {
    name = "requestId"
    type = "S"
  }

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "createdAt"
    type = "S"
  }

  global_secondary_index {
    name            = "byCreatedAt"
    projection_type = "ALL"

    key_schema {
      attribute_name = "pk"
      key_type       = "HASH"
    }

    key_schema {
      attribute_name = "createdAt"
      key_type       = "RANGE"
    }

    read_capacity  = 5
    write_capacity = 5
  }

  server_side_encryption {
    enabled = true # AWS-owned key, бесплатно
  }

  deletion_protection_enabled = var.deletion_protection

  tags = { Name = "${var.name}-history" }
}

# ---------------------------------------------------------------------------
# S3: архив генераций
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "artifacts" {
  bucket        = "${var.name}-artifacts-${data.aws_caller_identity.current.account_id}"
  force_destroy = var.force_destroy_buckets
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire-generations"
    status = "Enabled"

    filter {
      prefix = "generations/"
    }

    expiration {
      days = var.artifacts_retention_days
    }
  }
}

resource "aws_s3_bucket_policy" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.artifacts]
}
