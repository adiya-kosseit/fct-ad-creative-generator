terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.40"
    }
  }

  # Bootstrap хранит своё состояние локально (terraform.tfstate в этой папке,
  # он в .gitignore). Это единственный слой с локальным state: он создаёт
  # тот самый бакет, в котором живёт state основного окружения.
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Layer     = "bootstrap"
    }
  }
}
