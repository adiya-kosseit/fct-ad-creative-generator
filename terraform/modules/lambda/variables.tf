variable "name" {
  type = string
}

variable "source_dir" {
  description = "Папка с кодом функции (src/backend)"
  type        = string
}

variable "role_arn" {
  type = string
}

variable "environment" {
  type    = map(string)
  default = {}
}

variable "subnet_ids" {
  description = "Пустой список — функция вне VPC"
  type        = list(string)
  default     = []
}

variable "security_group_ids" {
  type    = list(string)
  default = []
}

variable "memory_mb" {
  type    = number
  default = 256
}

variable "timeout_seconds" {
  type    = number
  default = 29

  validation {
    condition     = var.timeout_seconds <= 29
    error_message = "HTTP API ждёт ответ максимум 30 с, таймаут функции должен быть не больше 29 с."
  }
}

variable "log_retention_days" {
  type    = number
  default = 7
}
