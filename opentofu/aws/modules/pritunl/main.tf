locals {
  name = "${var.building_block}-${var.environment}-pritunl"
  common_tags = {
    Environment   = var.environment
    BuildingBlock = var.building_block
    ManagedBy     = "Terraform"
    CloudProvider = "AWS"
  }

  # Public SSH keys for the one-time Pritunl setup shell (ubuntu user). Public keys
  # only — private keys stay with each owner and never enter Terraform state.
  authorized_keys_block = join("\n", var.authorized_keys)
}

data "aws_caller_identity" "current" {}

# Ubuntu 22.04 LTS — Pritunl has official apt packages for Ubuntu Jammy
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ── Security Group ──────────────────────────────────────────────────────────────

resource "aws_security_group" "pritunl" {
  name        = "${local.name}-sg"
  description = "Pritunl VPN: SSH 22 + OpenVPN 1194 (UDP+TCP) + web admin TCP 443"
  vpc_id      = var.vpc_id

  # All inbound sources are gated by var.ingress_cidrs. Default ["0.0.0.0/0"] (open); set to
  # office/home CIDRs in global-values.yaml (pritunl_ingress_cidrs) to restrict who can even
  # reach the VPN — which gates ALL downstream cluster access (bastion + EKS are VPN-only).
  ingress {
    description = "SSH for one-time Pritunl setup (pritunl setup-key / default-password). Key-auth only."
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ingress_cidrs
  }

  ingress {
    description = "OpenVPN over UDP (default, fastest)"
    from_port   = 1194
    to_port     = 1194
    protocol    = "udp"
    cidr_blocks = var.ingress_cidrs
  }

  ingress {
    description = "OpenVPN over TCP (fallback for networks that drop UDP)"
    from_port   = 1194
    to_port     = 1194
    protocol    = "tcp"
    cidr_blocks = var.ingress_cidrs
  }

  ingress {
    description = "Pritunl web admin UI"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.ingress_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${local.name}-sg" })
}

# ── IAM ─────────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "pritunl" {
  name               = "${local.name}-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
  tags               = local.common_tags
}

# Allow the VPN server to describe EKS clusters (for kubeconfig generation on the host)
resource "aws_iam_role_policy" "eks_describe" {
  name = "${local.name}-eks-describe"
  role = aws_iam_role.pritunl.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["eks:DescribeCluster", "eks:ListClusters"]
      Resource = "arn:aws:eks:${var.aws_region}:${data.aws_caller_identity.current.account_id}:cluster/*"
    }]
  })
}

resource "aws_iam_instance_profile" "pritunl" {
  name = "${local.name}-profile"
  role = aws_iam_role.pritunl.name
  tags = local.common_tags
}

# ── EC2 Instance ────────────────────────────────────────────────────────────────

resource "aws_instance" "pritunl" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = var.public_subnet_id
  key_name                    = var.key_name
  vpc_security_group_ids      = [aws_security_group.pritunl.id]
  iam_instance_profile        = aws_iam_instance_profile.pritunl.name
  associate_public_ip_address = false # EIP is used; prevent a redundant random public IP

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    encrypted             = true
    delete_on_termination = true
  }

  # Non-indented heredoc: lines written verbatim so the shebang stays at column 0 AND
  # the injected authorized_keys land at column 0 (sshd ignores keys with leading space).
  user_data = <<EOF
#!/bin/bash
set -euxo pipefail
curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg
echo "deb [ signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" > /etc/apt/sources.list.d/mongodb-org-7.0.list
curl -fsSL https://raw.githubusercontent.com/pritunl/pgp/master/pritunl_repo_pub.asc | gpg --dearmor -o /usr/share/keyrings/pritunl.gpg
echo "deb [ signed-by=/usr/share/keyrings/pritunl.gpg ] https://repo.pritunl.com/stable/apt jammy main" > /etc/apt/sources.list.d/pritunl.list
apt-get update -y
apt-get install -y mongodb-org pritunl
systemctl enable mongod pritunl
systemctl start mongod pritunl
install -d -m 700 -o ubuntu -g ubuntu /home/ubuntu/.ssh
cat >> /home/ubuntu/.ssh/authorized_keys <<'KEYS'
${local.authorized_keys_block}
KEYS
chmod 600 /home/ubuntu/.ssh/authorized_keys
chown ubuntu:ubuntu /home/ubuntu/.ssh/authorized_keys
EOF

  tags = merge(local.common_tags, { Name = local.name })

  depends_on = [
    aws_iam_role_policy.eks_describe,
  ]

  # The instance sits in a public subnet, so AWS auto-assigns a public IP at launch
  # (state shows associate_public_ip_address = true) even though we set false and use the
  # EIP instead. Ignore that attribute so day-2 changes (e.g. SG ingress edits) don't force
  # a destroy/recreate of the VPN host — which would wipe the Pritunl org/user/server config.
  lifecycle {
    ignore_changes = [associate_public_ip_address]
  }
}

# ── Elastic IP ──────────────────────────────────────────────────────────────────

resource "aws_eip" "pritunl" {
  domain = "vpc"
  tags   = merge(local.common_tags, { Name = "${local.name}-eip" })
}

resource "aws_eip_association" "pritunl" {
  instance_id   = aws_instance.pritunl.id
  allocation_id = aws_eip.pritunl.id
}
