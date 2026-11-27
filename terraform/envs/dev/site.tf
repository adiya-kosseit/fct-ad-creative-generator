# Выкладка фронтенда. index.html берётся из src/frontend как есть,
# адрес API подставляется отдельным config.js — фронтендеру не нужно
# править код после каждого apply.

locals {
  frontend_dir = "${path.module}/../../../src/frontend"

  config_js = <<-EOT
    // Сгенерировано Terraform. Не редактировать вручную.
    window.APP_CONFIG = {
      apiUrl: "${module.api.api_url}",
      environment: "${var.environment}"
    };
  EOT
}

resource "aws_s3_object" "index" {
  bucket        = module.frontend.bucket
  key           = "index.html"
  source        = "${local.frontend_dir}/index.html"
  etag          = filemd5("${local.frontend_dir}/index.html")
  content_type  = "text/html; charset=utf-8"
  cache_control = "no-cache"
}

resource "aws_s3_object" "config" {
  bucket        = module.frontend.bucket
  key           = "config.js"
  content       = local.config_js
  content_type  = "application/javascript; charset=utf-8"
  cache_control = "no-cache"
}
