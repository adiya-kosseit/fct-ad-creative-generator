variable "region" {
  description = "Регион AWS для state-бакета и всего проекта"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Короткий префикс для имён всех ресурсов"
  type        = string
  default     = "fct-adgen"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,20}$", var.project))
    error_message = "Только строчные латинские буквы, цифры и дефис, 3–20 символов."
  }
}

variable "team_members" {
  description = "IAM-пользователи команды: имя пользователя => роль (backend | frontend | qa)"
  type        = map(string)
  default = {
    dayana  = "backend"
    raushan = "frontend"
    arailym = "qa"
  }

  validation {
    condition     = alltrue([for r in values(var.team_members) : contains(["backend", "frontend", "qa"], r)])
    error_message = "Роль должна быть backend, frontend или qa."
  }
}
