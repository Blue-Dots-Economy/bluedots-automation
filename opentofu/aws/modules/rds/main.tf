locals {
  environment_name = "${var.building_block}-${var.environment}"
  name             = "${local.environment_name}-postgres"

  # Parameter group family is keyed on the MAJOR version: "17" or "17.4" → postgres17.
  engine_family = "postgres${split(".", var.engine_version)[0]}"

  common_tags = {
    Environment   = var.environment
    BuildingBlock = var.building_block
    ManagedBy     = "Terraform"
    CloudProvider = "AWS"
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# DB subnet group — RDS requires ≥2 subnets across ≥2 AZs (enforced in variables.tf)
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_db_subnet_group" "this" {
  name       = local.name
  subnet_ids = var.subnet_ids

  tags = merge(local.common_tags, { Name = local.name })
}

# ---------------------------------------------------------------------------------------------------------------------
# Security group — Postgres reachable ONLY from the allowed security groups (EKS nodes),
# never from the internet. Combined with publicly_accessible = false this keeps the DB private.
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_security_group" "rds" {
  name        = "${local.name}-sg"
  description = "Allow PostgreSQL ${var.db_port} from allowed security groups only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from allowed security groups (EKS nodes)"
    from_port       = var.db_port
    to_port         = var.db_port
    protocol        = "tcp"
    security_groups = var.allowed_security_group_ids
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${local.name}-sg" })
}

# ---------------------------------------------------------------------------------------------------------------------
# Parameter group — rds.force_ssl toggle. Default 0 so existing app/JDBC connection
# strings (which don't request TLS) keep working; flip force_ssl = true to harden.
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_db_parameter_group" "this" {
  name        = local.name
  family      = local.engine_family
  description = "Custom parameter group for ${local.name}"

  parameter {
    name         = "rds.force_ssl"
    value        = var.force_ssl ? "1" : "0"
    apply_method = "immediate"
  }

  tags = merge(local.common_tags, { Name = local.name })

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# PostgreSQL instance — encrypted gp3, private, multi-tenant (databases created by the
# common-services bootstrap Job, not here).
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_db_instance" "this" {
  identifier     = local.name
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage > 0 ? var.max_allocated_storage : null
  storage_type          = "gp3"
  storage_encrypted     = true

  username = var.master_username
  password = var.master_password
  port     = var.db_port

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.this.name
  publicly_accessible    = false

  multi_az                   = var.multi_az
  backup_retention_period    = var.backup_retention_days
  copy_tags_to_snapshot      = true
  auto_minor_version_upgrade = true

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${local.name}-final"
  apply_immediately         = var.apply_immediately

  tags = merge(local.common_tags, { Name = local.name })
}
