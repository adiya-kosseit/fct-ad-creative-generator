# Сеть: VPC в двух AZ, публичные и приватные подсети.
#
# Lambda работает в приватных подсетях без публичного IP.
#   * DynamoDB и S3 достигаются через бесплатные Gateway VPC Endpoints,
#     трафик не уходит в интернет.
#   * Gemini API и SSM нужен выход в интернет. NAT Gateway стоит ~$32/мес,
#     поэтому вместо него NAT-инстанс на t3.micro (free tier).

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

data "aws_region" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

# ---------------------------------------------------------------------------
# VPC и подсети
# ---------------------------------------------------------------------------
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-igw" }
}

# 10.20.0.0/24, 10.20.1.0/24
resource "aws_subnet" "public" {
  count                   = length(local.azs)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = { Name = "${var.name}-public-${local.azs[count.index]}", Tier = "public" }
}

# 10.20.10.0/24, 10.20.11.0/24
resource "aws_subnet" "private" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = local.azs[count.index]

  tags = { Name = "${var.name}-private-${local.azs[count.index]}", Tier = "private" }
}

# ---------------------------------------------------------------------------
# Маршрутизация
# ---------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-public-rt" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-private-rt" }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# Выход приватных подсетей в интернет через NAT-инстанс
resource "aws_route" "private_nat" {
  count                  = var.enable_nat ? 1 : 0
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.nat[0].primary_network_interface_id
}

# ---------------------------------------------------------------------------
# Gateway VPC Endpoints (бесплатные)
# ---------------------------------------------------------------------------
resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${var.name}-dynamodb-endpoint" }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${var.name}-s3-endpoint" }
}

# ---------------------------------------------------------------------------
# Security groups
# ---------------------------------------------------------------------------
resource "aws_security_group" "lambda" {
  name        = "${var.name}-lambda-sg"
  description = "Lambda: no inbound, outbound HTTPS only"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.name}-lambda-sg" }
}

resource "aws_vpc_security_group_egress_rule" "lambda_https" {
  security_group_id = aws_security_group.lambda.id
  description       = "HTTPS to Gemini, SSM, DynamoDB, S3"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "nat" {
  count       = var.enable_nat ? 1 : 0
  name        = "${var.name}-nat-sg"
  description = "NAT instance: HTTPS from private subnets only"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.name}-nat-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "nat_from_private" {
  count             = var.enable_nat ? length(aws_subnet.private) : 0
  security_group_id = aws_security_group.nat[0].id
  description       = "HTTPS from private subnet ${count.index}"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = aws_subnet.private[count.index].cidr_block
}

resource "aws_vpc_security_group_egress_rule" "nat_https" {
  count             = var.enable_nat ? 1 : 0
  security_group_id = aws_security_group.nat[0].id
  description       = "HTTPS to the internet"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

# HTTP нужен только самому инстансу для пакетного менеджера при загрузке
resource "aws_vpc_security_group_egress_rule" "nat_http" {
  count             = var.enable_nat ? 1 : 0
  security_group_id = aws_security_group.nat[0].id
  description       = "HTTP for OS package repositories"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

# ---------------------------------------------------------------------------
# NAT-инстанс
# ---------------------------------------------------------------------------
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# Роль только для Session Manager, чтобы зайти на инстанс без SSH и ключей
resource "aws_iam_role" "nat" {
  count = var.enable_nat ? 1 : 0
  name  = "${var.name}-nat-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "nat_ssm" {
  count      = var.enable_nat ? 1 : 0
  role       = aws_iam_role.nat[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "nat" {
  count = var.enable_nat ? 1 : 0
  name  = "${var.name}-nat-profile"
  role  = aws_iam_role.nat[0].name
}

resource "aws_instance" "nat" {
  count                       = var.enable_nat ? 1 : 0
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = var.nat_instance_type
  subnet_id                   = aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.nat[0].id]
  associate_public_ip_address = true
  source_dest_check           = false # обязательно для NAT
  iam_instance_profile        = aws_iam_instance_profile.nat[0].name
  user_data_replace_on_change = true

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail
    dnf install -y iptables-services
    systemctl enable --now iptables
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/90-nat.conf
    sysctl -p /etc/sysctl.d/90-nat.conf
    IFACE=$(ip route show default | awk '{print $5; exit}')
    iptables -t nat -A POSTROUTING -o "$IFACE" -s ${var.vpc_cidr} -j MASQUERADE
    iptables -F FORWARD
    service iptables save
  EOF

  metadata_options {
    http_tokens = "required" # IMDSv2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }

  # AMI обновляется регулярно — не пересоздаём NAT из-за каждой новой версии
  lifecycle {
    ignore_changes = [ami]
  }

  tags = { Name = "${var.name}-nat" }
}
