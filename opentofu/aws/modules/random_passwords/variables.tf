variable "keycloak_length" {
  type        = number
  description = "Length of the generated Keycloak admin password"
  default     = 16
}

variable "keycloak_special" {
  type        = bool
  description = "Whether the Keycloak admin password may include special characters"
  default     = true
}

variable "postgresql_length" {
  type        = number
  description = "Length of the generated PostgreSQL password"
  default     = 16
}

variable "postgresql_special" {
  type        = bool
  description = "Whether the PostgreSQL password may include special characters (postgres clients often dislike specials in URLs, so default false)"
  default     = false
}

variable "redis_length" {
  type        = number
  description = "Length of the generated Redis password"
  default     = 16
}

variable "redis_special" {
  type        = bool
  description = "Whether the Redis password may include special characters"
  default     = false
}

variable "encryption_string_length" {
  type        = number
  description = "Length of the generated encryption string (must be 32)"
  default     = 32
  validation {
    condition     = var.encryption_string_length == 32
    error_message = "encryption_string_length must be exactly 32."
  }
}

variable "random_string_length" {
  type        = number
  description = "Length of the generated app random/secret string (12–24)"
  default     = 24
  validation {
    condition     = var.random_string_length >= 12 && var.random_string_length <= 24
    error_message = "random_string_length must be between 12 and 24."
  }
}
