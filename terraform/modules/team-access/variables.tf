variable "project" {
  type = string
}

variable "members" {
  description = "Имя пользователя => роль (backend | frontend | qa)"
  type        = map(string)
}

variable "state_bucket_arn" {
  type = string
}

variable "lock_table_arn" {
  type = string
}
