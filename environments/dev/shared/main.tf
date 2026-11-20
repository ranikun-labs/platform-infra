locals {
  name = "dev-shared"
  tags = { Environment = "dev", Owner = "shared", ManagedBy = "terraform" }
}

resource "aws_vpc" "shared" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.tags, { Name = local.name })
}
resource "aws_internet_gateway" "shared" {
  vpc_id = aws_vpc.shared.id
  tags   = local.tags
}
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.shared.id
  availability_zone       = var.availability_zones[count.index]
  cidr_block              = var.public_subnet_cidrs[count.index]
  map_public_ip_on_launch = false
  tags                    = merge(local.tags, { Name = "${local.name}-public-${count.index + 1}" })
}
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.shared.id
  availability_zone = var.availability_zones[count.index]
  cidr_block        = var.private_subnet_cidrs[count.index]
  tags              = merge(local.tags, { Name = "${local.name}-private-${count.index + 1}" })
}
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.shared.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.shared.id
  }
  tags = local.tags
}
resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
resource "aws_eip" "nat" {
  count  = var.enable_nat_gateway ? 1 : 0
  domain = "vpc"
  tags   = local.tags
}
resource "aws_nat_gateway" "shared" {
  count         = var.enable_nat_gateway ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id
  depends_on    = [aws_internet_gateway.shared]
  tags          = local.tags
}
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.shared.id
  tags   = local.tags
}
resource "aws_route" "private_egress" {
  count                  = var.enable_nat_gateway ? 1 : 0
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.shared[0].id
}
resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
resource "aws_ecs_cluster" "shared" {
  name = local.name
  tags = local.tags
}
resource "aws_service_discovery_private_dns_namespace" "shared" {
  name = var.namespace_name
  vpc  = aws_vpc.shared.id
  tags = local.tags
}
resource "aws_security_group" "database" {
  name        = "${local.name}-database"
  description = "Aurora ingress from explicitly authorized workload security groups"
  vpc_id      = aws_vpc.shared.id
  tags        = local.tags
}
resource "aws_db_subnet_group" "shared" {
  name       = local.name
  subnet_ids = aws_subnet.private[*].id
  tags       = local.tags
}
resource "aws_rds_cluster" "database" {
  cluster_identifier          = local.name
  engine                      = "aurora-postgresql"
  engine_version              = var.database_engine_version
  database_name               = var.database_name
  master_username             = var.database_master_username
  manage_master_user_password = true
  db_subnet_group_name        = aws_db_subnet_group.shared.name
  vpc_security_group_ids      = [aws_security_group.database.id]
  storage_encrypted           = true
  backup_retention_period     = 7
  deletion_protection         = true
  skip_final_snapshot         = false
  final_snapshot_identifier   = "${local.name}-final"
  serverlessv2_scaling_configuration {
    min_capacity             = var.database_min_capacity
    max_capacity             = 1
    seconds_until_auto_pause = var.database_min_capacity == 0 ? var.database_auto_pause_seconds : null
  }
  tags = local.tags
}
resource "aws_rds_cluster_instance" "database" {
  identifier          = "${local.name}-1"
  cluster_identifier  = aws_rds_cluster.database.id
  instance_class      = "db.serverless"
  engine              = aws_rds_cluster.database.engine
  engine_version      = aws_rds_cluster.database.engine_version
  publicly_accessible = false
  tags                = local.tags
}
resource "aws_security_group" "valkey" {
  name        = "${local.name}-valkey"
  description = "Valkey ingress from explicitly authorized workload security groups"
  vpc_id      = aws_vpc.shared.id
  tags        = local.tags
}
resource "aws_elasticache_subnet_group" "valkey" {
  count      = var.enable_valkey ? 1 : 0
  name       = "${local.name}-valkey"
  subnet_ids = aws_subnet.private[*].id
}
resource "aws_elasticache_replication_group" "valkey" {
  count                      = var.enable_valkey ? 1 : 0
  replication_group_id       = "${local.name}-valkey"
  description                = "Private DEV Valkey"
  engine                     = "valkey"
  engine_version             = var.valkey_engine_version
  node_type                  = var.valkey_node_type
  num_cache_clusters         = 1
  port                       = 6379
  subnet_group_name          = aws_elasticache_subnet_group.valkey[0].name
  security_group_ids         = [aws_security_group.valkey.id]
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  tags                       = local.tags
}

# Shared owns inbound grants. Service roots create source groups first; a separate
# shared apply grants only the explicitly listed groups the fixed service ports.
resource "aws_vpc_security_group_ingress_rule" "database" {
  for_each                     = var.database_ingress_security_group_ids
  security_group_id            = aws_security_group.database.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL from approved workload ${each.key}"
}
resource "aws_vpc_security_group_ingress_rule" "valkey" {
  for_each                     = var.valkey_ingress_security_group_ids
  security_group_id            = aws_security_group.valkey.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
  description                  = "Valkey from approved workload ${each.key}"
}
