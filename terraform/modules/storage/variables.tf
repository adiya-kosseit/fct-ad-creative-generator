variable "name" {
  type = string
}

variable "deletion_protection" {
  description = "Защита таблицы от удаления. Для проверки destroy -> apply должна быть false."
  type        = bool
  default     = false
}

variable "force_destroy_buckets" {
  description = "Разрешить destroy удалять непустые бакеты"
  type        = bool
  default     = true
}

variable "artifacts_retention_days" {
  type    = number
  default = 30
}
