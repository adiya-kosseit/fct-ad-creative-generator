output "lambda_role_arn" {
  value = aws_iam_role.lambda.arn
  # Функция в VPC создаётся только после того, как роли выданы права на ENI
  depends_on = [aws_iam_role_policy_attachment.basic, aws_iam_role_policy.app]
}

output "lambda_role_name" {
  value = aws_iam_role.lambda.name
}

output "gemini_param_arn" {
  value = local.gemini_param_arn
}
