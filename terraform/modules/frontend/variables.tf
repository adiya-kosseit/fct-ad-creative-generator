variable "name" {
  type = string
}

variable "mode" {
  description = "cloudfront | s3_website"
  type        = string
  default     = "cloudfront"

  validation {
    condition     = contains(["cloudfront", "s3_website"], var.mode)
    error_message = "mode должен быть cloudfront или s3_website."
  }
}
