variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "fct-adgen"
}

variable "environment" {
  type    = string
  default = "dev"
}

# --- Gemini -----------------------------------------------------------------
variable "gemini_model" {
  description = "Модель Gemini. Проверена командой запросом к API."
  type        = string
  default     = "gemini-3.8-flash"
}

variable "gemini_thinking_level" {
  description = "minimal | low | medium | high. Чем ниже, тем быстрее ответ (лимит шлюза 29–30 с). Пусто — не передавать."
  type        = string
  default     = "low"
}

variable "gemini_api_key_parameter" {
  description = "Имя SecureString-параметра в SSM Parameter Store с ключом Gemini. Создаётся вручную, НЕ через Terraform, чтобы ключ не попал в state."
  type        = string
  default     = "/fct-adgen/gemini-api-key"
}

# --- Сеть -------------------------------------------------------------------
variable "lambda_in_vpc" {
  description = "Запускать Lambda в приватных подсетях VPC (тогда создаётся NAT-инстанс). false — запасной режим без NAT."
  type        = bool
  default     = true
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "nat_instance_type" {
  type    = string
  default = "t3.micro"
}

# --- Фронтенд и API ---------------------------------------------------------
variable "frontend_mode" {
  description = "cloudfront | s3_website (запасной, если аккаунту ещё нельзя CloudFront)"
  type        = string
  default     = "cloudfront"
}

variable "extra_cors_origins" {
  description = "Дополнительные адреса для CORS, например локальный сервер фронтендера"
  type        = list(string)
  default     = ["http://localhost:5500", "http://127.0.0.1:5500"]
}

# --- Мониторинг -------------------------------------------------------------
variable "alert_email" {
  description = "Почта для алармов; пусто — без email-подписки"
  type        = string
  default     = ""
}

variable "log_retention_days" {
  type    = number
  default = 7
}
