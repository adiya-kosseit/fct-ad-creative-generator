variable "name" {
  description = "Префикс имён, например fct-adgen-dev"
  type        = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "enable_nat" {
  description = "Создавать NAT-инстанс (нужен, если Lambda работает внутри VPC)"
  type        = bool
  default     = true
}

variable "nat_instance_type" {
  description = "t3.micro входит в free tier"
  type        = string
  default     = "t3.micro"
}
