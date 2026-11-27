variable "name" {
  type = string
}

variable "lambda_invoke_arn" {
  type = string
}

variable "lambda_function_name" {
  type = string
}

variable "cors_allow_origins" {
  description = "С каких адресов браузеру разрешено обращаться к API"
  type        = list(string)
}

variable "throttle_burst" {
  type    = number
  default = 10
}

variable "throttle_rate" {
  description = "Запросов в секунду в среднем"
  type        = number
  default     = 5
}

variable "log_retention_days" {
  type    = number
  default = 7
}
