# Unified VPC Module for DevOps Agent Workshop
# Supports both ECS and EKS deployments with shared networking

locals {
  private_subnets = [for k, v in var.azs : cidrsubnet(var.vpc_cidr, 8, k + 10)]
  public_subnets  = [for k, v in var.azs : cidrsubnet(var.vpc_cidr, 8, k)]

  # EKS-specific subnet tags (only applied when EKS is enabled)
  eks_public_subnet_tags = var.enable_eks ? {
    "kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
    "kubernetes.io/role/elb"                        = 1
  } : {}

  eks_private_subnet_tags = var.enable_eks ? {
    "kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"               = 1
  } : {}
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.21.0"

  name = var.environment_name
  cidr = var.vpc_cidr

  azs             = var.azs
  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets

  enable_nat_gateway   = true
  create_igw           = true
  enable_dns_hostnames = true
  single_nat_gateway   = true

  # Manage so we can name
  manage_default_network_acl    = true
  default_network_acl_tags      = { Name = "${var.environment_name}-default" }
  manage_default_route_table    = true
  default_route_table_tags      = { Name = "${var.environment_name}-default" }
  manage_default_security_group = true
  default_security_group_tags   = { Name = "${var.environment_name}-default" }

  # VPC Flow Logs (enabled for observability)
  enable_flow_log                                 = var.enable_flow_logs
  create_flow_log_cloudwatch_log_group            = var.enable_flow_logs
  create_flow_log_cloudwatch_iam_role             = var.enable_flow_logs
  flow_log_max_aggregation_interval               = 60
  flow_log_cloudwatch_log_group_retention_in_days = 30
  vpc_flow_log_tags                               = var.tags

  # Merge custom tags with EKS-specific tags
  public_subnet_tags  = merge(var.tags, var.public_subnet_tags, local.eks_public_subnet_tags)
  private_subnet_tags = merge(var.tags, var.private_subnet_tags, local.eks_private_subnet_tags)

  tags = var.tags
}
