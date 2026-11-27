# Окружение dev: связывает все модули в одно приложение.
#
#   Браузер ─► CloudFront ─► S3 (index.html, config.js)
#      │
#      └────► API Gateway (HTTP API) ─► Lambda (приватные подсети VPC)
#                                         ├─► DynamoDB  (gateway endpoint)
#                                         ├─► S3 архив  (gateway endpoint)
#                                         ├─► SSM Parameter Store (через NAT)
#                                         └─► Gemini API          (через NAT)

locals {
  name              = "${var.project}-${var.environment}" # fct-adgen-dev
  metrics_namespace = "AdCreativeGenerator"
}

module "network" {
  source = "../../modules/network"

  name              = local.name
  vpc_cidr          = var.vpc_cidr
  enable_nat        = var.lambda_in_vpc
  nat_instance_type = var.nat_instance_type
}

module "storage" {
  source = "../../modules/storage"

  name = local.name
}

module "iam" {
  source = "../../modules/iam"

  name                 = local.name
  table_arn            = module.storage.table_arn
  artifacts_bucket_arn = module.storage.artifacts_bucket_arn
  gemini_param_name    = var.gemini_api_key_parameter
  in_vpc               = var.lambda_in_vpc
}

module "lambda" {
  source = "../../modules/lambda"

  name               = "${local.name}-api"
  source_dir         = "${path.module}/../../../src/backend"
  role_arn           = module.iam.lambda_role_arn
  subnet_ids         = var.lambda_in_vpc ? module.network.private_subnet_ids : []
  security_group_ids = var.lambda_in_vpc ? [module.network.lambda_security_group_id] : []
  log_retention_days = var.log_retention_days

  environment = {
    TABLE_NAME            = module.storage.table_name
    ARTIFACTS_BUCKET      = module.storage.artifacts_bucket
    GEMINI_MODEL          = var.gemini_model
    GEMINI_THINKING_LEVEL = var.gemini_thinking_level
    GEMINI_PARAM_NAME     = var.gemini_api_key_parameter
    METRICS_NAMESPACE     = local.metrics_namespace
    APP_ENV               = var.environment
    MAX_SCENARIOS         = "4"
  }
}

module "frontend" {
  source = "../../modules/frontend"

  name = local.name
  mode = var.frontend_mode
}

module "api" {
  source = "../../modules/api"

  name                 = local.name
  lambda_invoke_arn    = module.lambda.invoke_arn
  lambda_function_name = module.lambda.function_name
  cors_allow_origins   = concat([module.frontend.site_url], var.extra_cors_origins)
  log_retention_days   = var.log_retention_days
}

module "monitoring" {
  source = "../../modules/monitoring"

  name                 = local.name
  environment          = var.environment
  alert_email          = var.alert_email
  lambda_function_name = module.lambda.function_name
  api_id               = module.api.api_id
  table_name           = module.storage.table_name
  metrics_namespace    = local.metrics_namespace
  nat_enabled          = var.lambda_in_vpc
  nat_instance_id      = module.network.nat_instance_id
}
