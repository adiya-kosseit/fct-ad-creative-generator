output "bucket" {
  value = aws_s3_bucket.site.bucket
}

output "site_url" {
  description = "Публичный адрес сайта"
  value = (local.use_cf
    ? "https://${aws_cloudfront_distribution.site[0].domain_name}"
    : "http://${aws_s3_bucket_website_configuration.site[0].website_endpoint}"
  )
}

output "distribution_id" {
  value = local.use_cf ? aws_cloudfront_distribution.site[0].id : null
}
