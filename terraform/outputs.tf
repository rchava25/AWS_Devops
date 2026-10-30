# =============================================================================
# Unified DevOps Agent Workshop - Root Outputs
# =============================================================================
# This file exposes outputs from all modules for use by CDK, scripts, and users.
# ECS and EKS stacks are completely independent - each has its own dependencies.
# =============================================================================

# -----------------------------------------------------------------------------
# GENERAL OUTPUTS
# -----------------------------------------------------------------------------

output "region" {
  description = "AWS region where resources are deployed"
  value       = local.region
}

output "account_id" {
  description = "AWS account ID"
  value       = local.aws_account_id
}

output "environment_name" {
  description = "Name of the workshop environment"
  value       = var.environment_name
}

# -----------------------------------------------------------------------------
# VPC OUTPUTS (SHARED)
# -----------------------------------------------------------------------------

output "vpc_id" {
  description = "ID of the shared VPC"
  value       = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC"
  value       = module.vpc.vpc_cidr_block
}

output "private_subnets" {
  description = "List of private subnet IDs"
  value       = module.vpc.private_subnets
}

output "public_subnets" {
  description = "List of public subnet IDs"
  value       = module.vpc.public_subnets
}

output "availability_zones" {
  description = "List of availability zones used"
  value       = local.azs
}

# -----------------------------------------------------------------------------
# ECS STACK OUTPUTS (Conditional)
# -----------------------------------------------------------------------------

output "ecs_enabled" {
  description = "Whether ECS stack is enabled"
  value       = var.enable_ecs
}

output "ecs_cluster_name" {
  description = "Name of the ECS cluster"
  value       = var.enable_ecs ? module.ecs[0].ecs_cluster_name : null
}

output "ecs_ui_service_url" {
  description = "URL of the ECS UI service (retail store application)"
  value       = var.enable_ecs ? module.ecs[0].ui_service_url : null
}

output "ecs_tasks_log_group" {
  description = "CloudWatch Log Group for ECS tasks"
  value       = var.enable_ecs ? module.ecs[0].ecs_tasks_log_group : null
}

# ECS Dependencies
output "ecs_catalog_db_endpoint" {
  description = "Endpoint of the ECS-specific catalog RDS database"
  value       = var.enable_ecs ? module.ecs_dependencies[0].catalog_db_endpoint : null
}

output "ecs_orders_db_endpoint" {
  description = "Endpoint of the ECS-specific orders RDS database"
  value       = var.enable_ecs ? module.ecs_dependencies[0].orders_db_endpoint : null
}

output "ecs_carts_dynamodb_table_name" {
  description = "Name of the ECS-specific carts DynamoDB table"
  value       = var.enable_ecs ? module.ecs_dependencies[0].carts_dynamodb_table_name : null
}

output "ecs_checkout_redis_endpoint" {
  description = "Endpoint of the ECS-specific checkout Redis cluster"
  value       = var.enable_ecs ? module.ecs_dependencies[0].checkout_elasticache_primary_endpoint : null
}

output "ecs_orders_sqs_queue_name" {
  description = "SQS queue name for ECS orders messaging"
  value       = var.enable_ecs ? module.ecs_dependencies[0].orders_sqs_queue_name : null
}

# ECS Security Groups
output "ecs_catalog_security_group_id" {
  description = "Security group ID for ECS catalog service"
  value       = var.enable_ecs ? module.ecs_security_groups[0].catalog_id : null
}

output "ecs_orders_security_group_id" {
  description = "Security group ID for ECS orders service"
  value       = var.enable_ecs ? module.ecs_security_groups[0].orders_id : null
}

# -----------------------------------------------------------------------------
# EKS STACK OUTPUTS (Conditional)
# -----------------------------------------------------------------------------

output "eks_enabled" {
  description = "Whether EKS stack is enabled"
  value       = var.enable_eks
}

output "eks_cluster_name" {
  description = "Name of the EKS cluster"
  value       = var.enable_eks ? module.eks[0].cluster_name : null
}

output "eks_cluster_endpoint" {
  description = "Endpoint URL for the EKS cluster API server"
  value       = var.enable_eks ? module.eks[0].cluster_endpoint : null
}

output "eks_cluster_arn" {
  description = "ARN of the EKS cluster"
  value       = var.enable_eks ? module.eks[0].cluster_arn : null
}

output "eks_cluster_version" {
  description = "Kubernetes version of the EKS cluster"
  value       = var.enable_eks ? module.eks[0].cluster_version : null
}

output "eks_cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data for the EKS cluster"
  value       = var.enable_eks ? module.eks[0].cluster_certificate_authority_data : null
}

output "eks_oidc_provider_arn" {
  description = "ARN of the OIDC provider for the EKS cluster"
  value       = var.enable_eks ? module.eks[0].oidc_provider_arn : null
}

output "eks_node_security_group_id" {
  description = "Security group ID for EKS nodes"
  value       = var.enable_eks ? module.eks[0].node_security_group_id : null
}

output "eks_grafana_workspace_endpoint" {
  description = "Endpoint of the Amazon Managed Grafana workspace (if enabled)"
  value       = var.enable_eks && var.eks_enable_grafana ? module.eks[0].grafana_workspace_endpoint : null
}

# EKS Dependencies (from eks-dependencies module)
output "eks_catalog_db_endpoint" {
  description = "Endpoint of the EKS-specific catalog RDS database"
  value       = var.enable_eks ? module.eks_dependencies[0].catalog_db_endpoint : null
}

output "eks_orders_db_endpoint" {
  description = "Endpoint of the EKS-specific orders RDS database"
  value       = var.enable_eks ? module.eks_dependencies[0].orders_db_endpoint : null
}

output "eks_carts_dynamodb_table_name" {
  description = "Name of the EKS-specific carts DynamoDB table"
  value       = var.enable_eks ? module.eks_dependencies[0].carts_dynamodb_table_name : null
}

output "eks_checkout_redis_endpoint" {
  description = "Endpoint of the EKS-specific checkout Redis cluster"
  value       = var.enable_eks ? module.eks_dependencies[0].checkout_elasticache_endpoint : null
}

output "eks_orders_sqs_queue_name" {
  description = "SQS queue name for EKS orders messaging"
  value       = var.enable_eks ? module.eks_dependencies[0].orders_sqs_queue_name : null
}

# EKS Sensitive Outputs (for deploy scripts)
output "eks_catalog_db_password" {
  description = "Password for the EKS-specific catalog RDS database"
  value       = var.enable_eks ? module.eks_dependencies[0].catalog_db_master_password : null
  sensitive   = true
}

output "eks_orders_db_password" {
  description = "Password for the EKS-specific orders RDS database"
  value       = var.enable_eks ? module.eks_dependencies[0].orders_db_master_password : null
  sensitive   = true
}

output "eks_orders_iam_role_arn" {
  description = "IAM role ARN for EKS orders service (IRSA)"
  value       = var.enable_eks ? module.eks_dependencies[0].orders_iam_role_arn : null
}

output "eks_carts_iam_role_arn" {
  description = "IAM role ARN for EKS carts service (IRSA)"
  value       = var.enable_eks ? module.eks_dependencies[0].carts_iam_role_arn : null
}

# -----------------------------------------------------------------------------
# CRM STACK OUTPUTS (Conditional)
# -----------------------------------------------------------------------------
# CRM values (CloudFront URL, User Pool ID, etc.) are written to SSM Parameter
# Store by the CDK deploy provisioner. We output the SSM parameter names and
# the deploy marker so consumers can read values from SSM at runtime.

output "crm_enabled" {
  description = "Whether CRM stack is enabled"
  value       = var.enable_crm
}

output "crm_deploy_complete" {
  description = "Marker that CRM CDK deployment is complete"
  value       = var.enable_crm ? module.crm[0].crm_deploy_complete : null
}

output "crm_login_password" {
  description = "Generated password for CRM workshop login"
  value       = var.enable_crm ? module.crm[0].crm_login_password : null
  sensitive   = true
}

output "crm_ssm_app_url" {
  description = "SSM parameter name for CRM application URL"
  value       = var.enable_crm ? module.crm[0].ssm_app_url : null
}

output "crm_ssm_user_pool_id" {
  description = "SSM parameter name for Cognito User Pool ID"
  value       = var.enable_crm ? module.crm[0].ssm_user_pool_id : null
}


# -----------------------------------------------------------------------------
# AMG + Keycloak + AMP STACK OUTPUTS (Conditional)
# -----------------------------------------------------------------------------

output "amg_keycloak_idp_enabled" {
  description = "Whether the AMG/Keycloak/AMP stack is enabled"
  value       = var.enable_eks && var.enable_amg_keycloak_idp
}

output "amg_workspace_url" {
  description = "Amazon Managed Grafana workspace URL"
  value       = var.enable_eks && var.enable_amg_keycloak_idp ? module.amg_keycloak_idp[0].grafana_workspace_url : null
}

output "amg_workspace_id" {
  description = "Amazon Managed Grafana workspace ID"
  value       = var.enable_eks && var.enable_amg_keycloak_idp ? module.amg_keycloak_idp[0].grafana_workspace_id : null
}

output "amp_workspace_id" {
  description = "Amazon Managed Prometheus workspace ID"
  value       = var.enable_eks && var.enable_amg_keycloak_idp ? module.amg_keycloak_idp[0].amp_workspace_id : null
}

output "amp_query_url" {
  description = "AMP query endpoint URL"
  value       = var.enable_eks && var.enable_amg_keycloak_idp ? module.amg_keycloak_idp[0].amp_query_url : null
}

output "amp_remote_write_url" {
  description = "AMP remote write endpoint URL"
  value       = var.enable_eks && var.enable_amg_keycloak_idp ? module.amg_keycloak_idp[0].amp_remote_write_url : null
}

output "keycloak_endpoint" {
  description = "Public Keycloak endpoint (HTTP API Gateway)"
  value       = var.enable_eks && var.enable_amg_keycloak_idp ? module.amg_keycloak_idp[0].keycloak_endpoint : null
}

output "keycloak_saml_metadata_url" {
  description = "SAML metadata URL configured in AMG"
  value       = var.enable_eks && var.enable_amg_keycloak_idp ? module.amg_keycloak_idp[0].keycloak_saml_metadata_url : null
}

output "amg_keycloak_consolidated_secret_arn" {
  description = "ARN of the consolidated AMG/Keycloak secret"
  value       = var.enable_eks && var.enable_amg_keycloak_idp ? module.amg_keycloak_idp[0].consolidated_secret_arn : null
}
