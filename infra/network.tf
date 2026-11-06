# Networking: VPC, subnets (public / private-app / private-data), IGW, optional single NAT gateway and route tables.

# 2 AZs, 6 subnets: 2 public (ALB/ingress futuro) + 4 private (2 app + 2 data),
# repartidas 1 por tier por AZ.
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  public_subnets = {
    a = { cidr = "10.0.0.0/24", az = local.azs[0] }
    b = { cidr = "10.0.1.0/24", az = local.azs[1] }
  }

  private_app_subnets = {
    a = { cidr = "10.0.10.0/24", az = local.azs[0] }
    b = { cidr = "10.0.11.0/24", az = local.azs[1] }
  }

  private_data_subnets = {
    a = { cidr = "10.0.20.0/24", az = local.azs[0] }
    b = { cidr = "10.0.21.0/24", az = local.azs[1] }
  }
}

resource "aws_vpc" "uniflow_vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name     = "${var.project-tag}-vpc"
    projects = var.project-tag
  }
}

resource "aws_internet_gateway" "uniflow_igw" {
  vpc_id = aws_vpc.uniflow_vpc.id

  tags = {
    Name     = "${var.project-tag}-igw"
    projects = var.project-tag
  }
}

resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.uniflow_vpc.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = true

  tags = {
    Name     = "${var.project-tag}-public-${each.key}"
    projects = var.project-tag
    Tier     = "public"
  }
}

resource "aws_subnet" "private_app" {
  for_each = local.private_app_subnets

  vpc_id            = aws_vpc.uniflow_vpc.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az

  tags = {
    Name     = "${var.project-tag}-private-app-${each.key}"
    projects = var.project-tag
    Tier     = "private-app"
  }
}

resource "aws_subnet" "private_data" {
  for_each = local.private_data_subnets

  vpc_id            = aws_vpc.uniflow_vpc.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az

  tags = {
    Name     = "${var.project-tag}-private-data-${each.key}"
    projects = var.project-tag
    Tier     = "private-data"
  }
}

# NAT gateway único (no uno por AZ) para minimizar costo — trade-off: las 4
# subnets privadas pierden salida a internet si la AZ del NAT cae.
# Optional (var.enable_nat_gateway, default false): the demo runs Fargate tasks
# in the public subnets instead, so the private tiers have no internet egress.
resource "aws_eip" "nat" {
  count  = var.enable_nat_gateway ? 1 : 0
  domain = "vpc"

  tags = {
    Name     = "${var.project-tag}-nat-eip"
    projects = var.project-tag
  }
}

resource "aws_nat_gateway" "uniflow_nat" {
  count         = var.enable_nat_gateway ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public["a"].id

  tags = {
    Name     = "${var.project-tag}-nat"
    projects = var.project-tag
  }

  depends_on = [aws_internet_gateway.uniflow_igw]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.uniflow_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.uniflow_igw.id
  }

  tags = {
    Name     = "${var.project-tag}-public-rt"
    projects = var.project-tag
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.uniflow_vpc.id

  dynamic "route" {
    for_each = var.enable_nat_gateway ? [1] : []

    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.uniflow_nat[0].id
    }
  }

  tags = {
    Name     = "${var.project-tag}-private-rt"
    projects = var.project-tag
  }
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private_app" {
  for_each = aws_subnet.private_app

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_data" {
  for_each = aws_subnet.private_data

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}
