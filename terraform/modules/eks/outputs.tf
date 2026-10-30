# EKS Module Outputs
# Exposes cluster information for use by other modules and root configuration

# =============================================================================
# CLUSTER OUTPUTS
# =============================================================================

output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "cluster_arn" {
  description = "ARN of the EKS cluster"
  value       = module.eks.cluster_arn
}

output "cluster_id" {
  description = "ID of the EKS cluster (same as cluster_name for EKS)"
  value       = module.eks.cluster_id
}

output "cluster_endpoint" {
  description = "Endpoint URL for the EKS cluster API server"
  value       = module.eks.cluster_endpoint
}

output "cluster_version" {
  description = "Kubernetes version of the EKS cluster"
  value       = module.eks.cluster_version
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data for the cluster"
  value       = module.eks.cluster_certificate_authority_data
}

# =============================================================================
# SECURITY OUTPUTS
# =============================================================================

output "cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster"
  value       = module.eks.cluster_security_group_id
}

output "node_security_group_id" {
  description = "Security group ID attached to the EKS nodes"
  value       = module.eks.node_security_group_id
}

output "cluster_primary_security_group_id" {
  description = "Primary security group ID of the EKS cluster"
  value       = module.eks.cluster_primary_security_group_id
}

# =============================================================================
# IAM OUTPUTS
# =============================================================================

output "cluster_iam_role_arn" {
  description = "ARN of the IAM role used by the EKS cluster"
  value       = aws_iam_role.eks_auto_cluster.arn
}

output "cluster_iam_role_name" {
  description = "Name of the IAM role used by the EKS cluster"
  value       = aws_iam_role.eks_auto_cluster.name
}

output "node_iam_role_arn" {
  description = "ARN of the IAM role used by EKS Auto Mode nodes"
  value       = aws_iam_role.eks_auto_node.arn
}

output "node_iam_role_name" {
  description = "Name of the IAM role used by EKS Auto Mode nodes"
  value       = aws_iam_role.eks_auto_node.name
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC provider for the EKS cluster"
  value       = module.eks.oidc_provider_arn
}

output "oidc_provider" {
  description = "OIDC provider URL (without https://)"
  value       = module.eks.oidc_provider
}

# =============================================================================
# AUTH OUTPUTS
# =============================================================================

output "cluster_auth_token" {
  description = "Authentication token for the EKS cluster"
  value       = data.aws_eks_cluster_auth.this.token
  sensitive   = true
}

# =============================================================================
# ALB LOGS BUCKET
# =============================================================================

output "alb_logs_bucket_name" {
  description = "Name of the S3 bucket for ALB access logs"
  value       = aws_s3_bucket.alb_logs.id
}

output "alb_logs_bucket_arn" {
  description = "ARN of the S3 bucket for ALB access logs"
  value       = aws_s3_bucket.alb_logs.arn
}

# =============================================================================
# DEPENDENCY BLOCKERS (for orchestrating deployments)
# =============================================================================

output "cluster_blocker" {
  description = "Resource that blocks until cluster is ready"
  value       = null_resource.cluster_blocker.id
}

output "cluster_ready" {
  description = "Blocks until the EKS cluster is created AND the cluster-admin access entry has propagated (safe to create Kubernetes resources after this)."
  value       = time_sleep.eks_access_propagation.id
}

# =============================================================================
# OBSERVABILITY OUTPUTS
# =============================================================================

output "grafana_workspace_endpoint" {
  description = "Endpoint of the Amazon Managed Grafana workspace (if enabled)"
  value       = var.enable_grafana ? aws_grafana_workspace.retail_store[0].endpoint : null
}

output "grafana_workspace_id" {
  description = "ID of the Amazon Managed Grafana workspace (if enabled)"
  value       = var.enable_grafana ? aws_grafana_workspace.retail_store[0].id : null
}

output "cloudwatch_observability_role_arn" {
  description = "ARN of the IAM role for CloudWatch observability"
  value       = aws_iam_role.cloudwatch_observability.arn
}
