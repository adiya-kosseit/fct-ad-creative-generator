variable "name" {
  type = string
}

variable "environment" {
  type = string
}

variable "alert_email" {
  description = "Почта для оповещений; пусто — без подписки"
  type        = string
  default     = ""
}

variable "lambda_function_name" {
  type = string
}

variable "api_id" {
  type = string
}

variable "table_name" {
  type = string
}

variable "metrics_namespace" {
  type    = string
  default = "AdCreativeGenerator"
}

variable "nat_enabled" {
  description = "Известное на этапе plan значение: есть ли NAT-инстанс"
  type        = bool
  default     = false
}

variable "nat_instance_id" {
  type    = string
  default = null
}
