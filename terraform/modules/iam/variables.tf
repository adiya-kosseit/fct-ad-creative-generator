variable "name" {
  type = string
}

variable "table_arn" {
  type = string
}

variable "artifacts_bucket_arn" {
  type = string
}

variable "gemini_param_name" {
  description = "Имя параметра SSM с ключом Gemini, например /fct-adgen/gemini-api-key"
  type        = string
}

variable "in_vpc" {
  type    = bool
  default = true
}
