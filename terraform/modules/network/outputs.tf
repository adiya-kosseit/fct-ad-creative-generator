output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "lambda_security_group_id" {
  value = aws_security_group.lambda.id
}

output "nat_instance_id" {
  value = var.enable_nat ? aws_instance.nat[0].id : null
}

output "nat_public_ip" {
  value = var.enable_nat ? aws_instance.nat[0].public_ip : null
}
