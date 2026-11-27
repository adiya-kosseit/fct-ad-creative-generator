output "users" {
  value = { for name, role in var.members : name => aws_iam_group.role[role].name }
}

output "group_names" {
  value = [for g in aws_iam_group.role : g.name]
}
