locals {
  environment_name = "${var.building_block}-${var.environment}"

  common_tags = {
    Environment   = var.environment
    BuildingBlock = var.building_block
    ManagedBy     = "Terraform"
    CloudProvider = "AWS"
  }

  # Developers' public keys, one per line, written verbatim into ec2-user's
  # authorized_keys. Each dev keeps their own private key locally — only public
  # keys ever reach here, so nothing secret lands in Terraform state.
  authorized_keys_block = join("\n", var.authorized_keys)
}

# ---------------------------------------------------------------------------------------------------------------------
# AMI — latest Amazon Linux 2023 (x86_64)
# ---------------------------------------------------------------------------------------------------------------------

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# Security group — SSH from VPC CIDR only
# Bastion is in a private subnet with no public IP. The only way to reach this
# IP is through the Pritunl VPN (which routes the VPC CIDR to the developer's laptop).
# No internet traffic can ever hit this security group — the subnet has no IGW route.
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_security_group" "bastion" {
  name        = "${local.environment_name}-bastion"
  description = "Bastion - SSH from VPC CIDR only (requires Pritunl VPN to reach)"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH - VPC-internal only; reachable only after VPN connect"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Allow all outbound (kubectl, aws cli, psql via VPC)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${local.environment_name}-bastion-sg" })
}

# ---------------------------------------------------------------------------------------------------------------------
# IAM role — eks:DescribeCluster so `aws eks update-kubeconfig` works on the bastion.
# Access to the box is SSH-only (via the EC2 key pair, reachable only through the VPN).
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_iam_role" "bastion" {
  name = "${local.environment_name}-bastion"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "eks_describe" {
  name = "eks-describe"
  role = aws_iam_role.bastion.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["eks:DescribeCluster", "eks:ListClusters"]
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${local.environment_name}-bastion"
  role = aws_iam_role.bastion.name
  tags = local.common_tags
}

# ---------------------------------------------------------------------------------------------------------------------
# EC2 instance — private subnet, no public IP, no EIP
# Reachable only from inside the VPC (i.e. after connecting Pritunl VPN).
# kubectl pre-installed so this works as an emergency kubectl host when needed.
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  key_name                    = var.key_name
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  iam_instance_profile        = aws_iam_instance_profile.bastion.name
  associate_public_ip_address = false

  # Deployment workstation: sized for repo clones, helm chart caches, and the toolchain.
  # The AMI default root is too small — installs hit "no space left on device".
  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    encrypted             = true
    delete_on_termination = true
  }

  # Non-indented heredoc: every line is written verbatim (no whitespace stripping), so
  # the shebang stays at column 0 AND the injected authorized_keys land at column 0
  # (sshd ignores authorized_keys lines that begin with whitespace).
  # The bastion is a DEPLOYMENT workstation: developers SSH in, `git pull`, and run
  # helm/kubectl from here. No repo code is baked in — it is pulled manually.
  # Toolchain: kubectl, helm, aws-cli v2, k9s, git, yq, make, openssl.
  # kubeconfig is pre-generated for ec2-user at boot (runs after eks, so the cluster
  # exists), so `kubectl`/`helm` work the moment you SSH in — no manual update-kubeconfig.
  user_data = <<EOF
#!/bin/bash
set -euxo pipefail
dnf install -y git make openssl tar gzip unzip
curl -fsSL "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl
chmod +x /usr/local/bin/kubectl
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64" -o /usr/local/bin/yq
chmod +x /usr/local/bin/yq
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install --update
curl -fsSL "https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_amd64.tar.gz" -o /tmp/k9s.tar.gz
tar -xzf /tmp/k9s.tar.gz -C /usr/local/bin k9s
install -d -m 700 -o ec2-user -g ec2-user /home/ec2-user/.ssh
cat >> /home/ec2-user/.ssh/authorized_keys <<'KEYS'
${local.authorized_keys_block}
KEYS
chmod 600 /home/ec2-user/.ssh/authorized_keys
chown ec2-user:ec2-user /home/ec2-user/.ssh/authorized_keys
sudo -u ec2-user -H /usr/local/bin/aws eks update-kubeconfig --name ${var.cluster_name} --region ${var.aws_region} || true
EOF

  depends_on = [aws_iam_role_policy.eks_describe]

  tags = merge(local.common_tags, { Name = "${local.environment_name}-bastion" })
}

# ---------------------------------------------------------------------------------------------------------------------
# EKS access entry — map the bastion IAM role into the cluster's Kubernetes RBAC.
# The cluster runs authentication_mode = API_AND_CONFIG_MAP, so access is granted via
# the access-entry API (no manual aws-auth ConfigMap editing).
#
# eks:DescribeCluster (above) lets `aws eks update-kubeconfig` build the kubeconfig;
# this entry is what actually authorizes kubectl/helm calls inside the cluster.
# Scope is cluster-wide ClusterAdmin: the bastion deploys across all namespaces
# (common-services, dpg, aggregator), and reaching it already requires VPN + SSH key.
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_eks_access_entry" "bastion" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.bastion.arn
  type          = "STANDARD"
  tags          = local.common_tags
}

resource "aws_eks_access_policy_association" "bastion" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.bastion.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.bastion]
}
