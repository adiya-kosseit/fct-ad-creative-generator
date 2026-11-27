output "api_id" {
  value = aws_apigatewayv2_api.this.id
}

output "api_url" {
  description = "Базовый адрес API без слэша в конце"
  value       = trimsuffix(aws_apigatewayv2_api.this.api_endpoint, "/")
}

output "access_log_group_name" {
  value = aws_cloudwatch_log_group.access.name
}
