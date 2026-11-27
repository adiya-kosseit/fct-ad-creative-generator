# Хостинг статического фронтенда.
#
# mode = "cloudfront" (по умолчанию): приватный бакет + CloudFront с OAC.
#   HTTPS, бакет закрыт от интернета, читать его может только этот дистрибутив.
# mode = "s3_website": запасной вариант. Новым аккаунтам AWS иногда
#   запрещают создавать CloudFront до верификации — тогда сайт отдаётся
#   прямо из S3 по HTTP.

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  use_cf = var.mode == "cloudfront"
}

resource "aws_s3_bucket" "site" {
  bucket        = "${var.name}-frontend-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "site" {
  bucket = aws_s3_bucket.site.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = local.use_cf
  restrict_public_buckets = local.use_cf
}

# ---------------------------------------------------------------------------
# Вариант CloudFront
# ---------------------------------------------------------------------------
data "aws_cloudfront_cache_policy" "optimized" {
  count = local.use_cf ? 1 : 0
  name  = "Managed-CachingOptimized"
}

data "aws_cloudfront_response_headers_policy" "security" {
  count = local.use_cf ? 1 : 0
  name  = "Managed-SecurityHeadersPolicy"
}

resource "aws_cloudfront_origin_access_control" "site" {
  count                             = local.use_cf ? 1 : 0
  name                              = "${var.name}-site-oac"
  description                       = "CloudFront -> private S3 bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "site" {
  count               = local.use_cf ? 1 : 0
  enabled             = true
  comment             = "${var.name} frontend"
  default_root_object = "index.html"
  price_class         = "PriceClass_100"
  http_version        = "http2and3"

  origin {
    origin_id                = "s3-site"
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.site[0].id
  }

  default_cache_behavior {
    target_origin_id           = "s3-site"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.optimized[0].id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security[0].id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

resource "aws_s3_bucket_policy" "cf_read" {
  count  = local.use_cf ? 1 : 0
  bucket = aws_s3_bucket.site.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontOAC"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.site.arn}/*"
      Condition = {
        StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.site[0].arn }
      }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.site]
}

# ---------------------------------------------------------------------------
# Запасной вариант: S3 static website
# ---------------------------------------------------------------------------
resource "aws_s3_bucket_website_configuration" "site" {
  count  = local.use_cf ? 0 : 1
  bucket = aws_s3_bucket.site.id

  index_document {
    suffix = "index.html"
  }
}

resource "aws_s3_bucket_policy" "public_read" {
  count  = local.use_cf ? 0 : 1
  bucket = aws_s3_bucket.site.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicReadSiteFiles"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.site.arn}/*"
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.site]
}
