variable "environment" {
  description = "Environment name"
  type        = string
}

variable "building_block" {
  description = "Building block name"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the Pritunl EC2 will be placed"
  type        = string
}

variable "public_subnet_id" {
  description = "Public subnet ID for the Pritunl EC2 (must have an internet gateway route)"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type. Minimum t3.small — MongoDB requires ~1 GB RAM"
  type        = string
  default     = "t3.small"
}
