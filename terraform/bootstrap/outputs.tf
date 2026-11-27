output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "lock_table" {
  value = aws_dynamodb_table.lock.name
}

output "team_users" {
  description = "Созданные IAM-пользователи и их группы"
  value       = module.team_access.users
}

output "console_sign_in_url" {
  value = "https://${data.aws_caller_identity.current.account_id}.signin.aws.amazon.com/console"
}

# Готовое содержимое для terraform/envs/dev/backend.hcl
output "backend_hcl" {
  value = <<-EOT
    bucket         = "${aws_s3_bucket.state.bucket}"
    key            = "envs/dev/terraform.tfstate"
    region         = "${var.region}"
    dynamodb_table = "${aws_dynamodb_table.lock.name}"
    encrypt        = true
  EOT
}
