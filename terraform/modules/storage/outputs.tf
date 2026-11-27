output "table_name" {
  value = aws_dynamodb_table.history.name
}

output "table_arn" {
  value = aws_dynamodb_table.history.arn
}

output "artifacts_bucket" {
  value = aws_s3_bucket.artifacts.bucket
}

output "artifacts_bucket_arn" {
  value = aws_s3_bucket.artifacts.arn
}
