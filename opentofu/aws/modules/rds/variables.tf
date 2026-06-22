variable "environment" {
  description = "Environment name"
  type        = string
}

variable "building_block" {
  description = "Building block name (naming prefix)"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

# ---------------------------------------------------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------------------------------------------------

variable "vpc_id" {
  description = "VPC the RDS instance + its security group live in"
  type        = string
}

variable "subnet_ids" {
  description = <<-EOT
    Subnet IDs for the DB subnet group. RDS requires at least 2 subnets in 2 different
    Availability Zones — even for a Single-AZ instance. Use private subnets (prod) or
    public subnets (dev); the instance stays publicly_accessible = false either way.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "RDS needs at least 2 subnets across 2 AZs for the DB subnet group."
  }
}

variable "allowed_security_group_ids" {
  description = "Security group IDs allowed to reach Postgres on db_port (typically the EKS cluster security group)."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------------------------------------------------
# Credentials
# ---------------------------------------------------------------------------------------------------------------------

variable "master_username" {
  description = "Master username. The bootstrap Job creates the per-tenant roles/databases on top of this."
  type        = string
  default     = "postgres"
}

variable "master_password" {
  description = "Master user password (sourced from the random_passwords module)."
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------------------------------------------------------------
# Engine / sizing
# ---------------------------------------------------------------------------------------------------------------------

variable "engine_version" {
  description = "PostgreSQL major (or major.minor) version. Major-only lets RDS pick the latest minor."
  type        = string
  default     = "17"
}

# This is the default instance class for dev (db.t4g.micro). For prod with large databases it is recommended to use the larger instance type (eg. m7g.large). Module users can override this variable to use a different instance class if needed.
variable "instance_class" {
  description = "RDS instance class, e.g. db.t4g.micro (dev) / db.t4g.small (prod)."
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "Initial gp3 storage in GiB (minimum 20 for gp3 Postgres)."
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = "Upper bound for storage autoscaling in GiB. Set 0 to disable autoscaling."
  type        = number
  default     = 0
}

variable "db_port" {
  description = "TCP port Postgres listens on."
  type        = number
  default     = 5432
}

variable "multi_az" {
  description = "Run a hot standby in a second AZ (~2x instance cost). false for dev, true for prod."
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  description = "Automated backup retention in days (0 disables backups; > 0 enables PITR)."
  type        = number
  default     = 7
}

variable "deletion_protection" {
  description = "Block accidental destroy / console deletion of the instance."
  type        = bool
  default     = true
}

variable "skip_final_snapshot" {
  description = "Skip the final snapshot on deletion. Keep false in prod so a snapshot is taken."
  type        = bool
  default     = false
}

variable "force_ssl" {
  description = <<-EOT
    When true, set rds.force_ssl = 1 (reject non-TLS connections). Left false initially so existing
    app/JDBC connection strings (which don't request SSL) keep working; harden to true later.
  EOT
  type        = bool
  default     = false
}

variable "apply_immediately" {
  description = "Apply modifications immediately instead of during the next maintenance window."
  type        = bool
  default     = false
}
