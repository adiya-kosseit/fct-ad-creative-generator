output "app_url" {
  description = "Публичный адрес приложения — его открывать на демо"
  value       = module.frontend.site_url
}

output "api_url" {
  description = "Адрес API без слэша в конце"
  value       = module.api.api_url
}

output "lambda_function_name" {
  value = module.lambda.function_name
}

output "lambda_log_group" {
  value = module.lambda.log_group_name
}

output "history_table" {
  value = module.storage.table_name
}

output "artifacts_bucket" {
  value = module.storage.artifacts_bucket
}

output "frontend_bucket" {
  value = module.frontend.bucket
}

output "cloudfront_distribution_id" {
  value = module.frontend.distribution_id
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "nat_instance_id" {
  value = module.network.nat_instance_id
}

output "nat_public_ip" {
  description = "С этого IP Lambda ходит в Gemini"
  value       = module.network.nat_public_ip
}

output "dashboard_url" {
  value = module.monitoring.dashboard_url
}
