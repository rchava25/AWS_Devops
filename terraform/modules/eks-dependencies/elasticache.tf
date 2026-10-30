# =============================================================================
# CHECKOUT CACHE (ElastiCache Redis) - EKS Specific
# =============================================================================

module "checkout_elasticache_redis" {
  source  = "cloudposse/elasticache-redis/aws"
  version = "0.53.0"

  name                       = "${var.environment_name}-checkout"
  vpc_id                     = var.vpc_id
  instance_type              = "cache.t3.micro"
  subnets                    = var.subnet_ids
  transit_encryption_enabled = false
  tags                       = var.tags

  # EKS Auto Mode uses cluster security group
  allowed_security_group_ids = [var.eks_cluster_security_group_id]
}
