# VPC Module Outputs
# Exposes all required values for both ECS and EKS deployments

# =============================================================================
# CORE VPC OUTPUTS
# =============================================================================

output "vpc_id" {
  value       = module.vpc.vpc_id
  description = "ID of the VPC"
}

output "vpc_arn" {
  value       = module.vpc.vpc_arn
  description = "ARN of the VPC"
}

output "vpc_cidr_block" {
  value       = module.vpc.vpc_cidr_block
  description = "CIDR block of the VPC (used by EKS security groups for CIDR-based rules)"
}

# =============================================================================
# SUBNET OUTPUTS
# =============================================================================

output "private_subnets" {
  value       = module.vpc.private_subnets
  description = "List of private subnet IDs (used by ECS services, EKS nodes, RDS, ElastiCache)"
}

output "public_subnets" {
  value       = module.vpc.public_subnets
  description = "List of public subnet IDs (used by ALBs, NAT Gateways)"
}

output "private_subnet_cidr_blocks" {
  value       = module.vpc.private_subnets_cidr_blocks
  description = "List of private subnet CIDR blocks"
}

output "public_subnet_cidr_blocks" {
  value       = module.vpc.public_subnets_cidr_blocks
  description = "List of public subnet CIDR blocks"
}

output "private_subnet_arns" {
  value       = module.vpc.private_subnet_arns
  description = "List of private subnet ARNs"
}

output "public_subnet_arns" {
  value       = module.vpc.public_subnet_arns
  description = "List of public subnet ARNs"
}

# =============================================================================
# DATABASE SUBNET OUTPUTS (for RDS, ElastiCache)
# =============================================================================

output "database_subnet_group_name" {
  value       = module.vpc.database_subnet_group_name
  description = "Name of the database subnet group (if created)"
}

output "database_subnets" {
  value       = module.vpc.database_subnets
  description = "List of database subnet IDs (if created)"
}

output "database_subnet_arns" {
  value       = module.vpc.database_subnet_arns
  description = "List of database subnet ARNs (if created)"
}

output "database_subnet_cidr_blocks" {
  value       = module.vpc.database_subnets_cidr_blocks
  description = "List of database subnet CIDR blocks (if created)"
}

# =============================================================================
# GATEWAY OUTPUTS
# =============================================================================

output "nat_gateway_ids" {
  value       = module.vpc.natgw_ids
  description = "List of NAT Gateway IDs"
}

output "nat_public_ips" {
  value       = module.vpc.nat_public_ips
  description = "List of public Elastic IPs created for NAT Gateways (useful for allowlisting)"
}

output "internet_gateway_id" {
  value       = module.vpc.igw_id
  description = "ID of the Internet Gateway"
}

output "internet_gateway_arn" {
  value       = module.vpc.igw_arn
  description = "ARN of the Internet Gateway"
}

# =============================================================================
# ROUTE TABLE OUTPUTS
# =============================================================================

output "private_route_table_ids" {
  value       = module.vpc.private_route_table_ids
  description = "List of private route table IDs"
}

output "public_route_table_ids" {
  value       = module.vpc.public_route_table_ids
  description = "List of public route table IDs"
}

# =============================================================================
# SECURITY GROUP OUTPUTS
# =============================================================================

output "default_security_group_id" {
  value       = module.vpc.default_security_group_id
  description = "ID of the default security group"
}

# =============================================================================
# AVAILABILITY ZONE OUTPUTS
# =============================================================================

output "availability_zones" {
  value       = var.azs
  description = "List of availability zones where the VPC was created"
}

output "azs" {
  value       = var.azs
  description = "List of availability zones (alias for availability_zones)"
}

# =============================================================================
# VPC FLOW LOG OUTPUTS
# =============================================================================

output "vpc_flow_log_id" {
  value       = module.vpc.vpc_flow_log_id
  description = "ID of the VPC Flow Log"
}

output "vpc_flow_log_cloudwatch_iam_role_arn" {
  value       = module.vpc.vpc_flow_log_cloudwatch_iam_role_arn
  description = "ARN of the IAM role used for VPC Flow Logs"
}

# =============================================================================
# PASS-THROUGH FOR ADVANCED USE CASES
# =============================================================================

# Pass through the inner module for advanced use cases
# This allows access to any output from the underlying terraform-aws-modules/vpc/aws module
output "inner" {
  value       = module.vpc
  description = "Full outputs from the underlying VPC module (for advanced use cases)"
}
