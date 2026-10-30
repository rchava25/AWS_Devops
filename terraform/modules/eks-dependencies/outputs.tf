# =============================================================================
# EKS Dependencies Module - Outputs
# =============================================================================

# Catalog Database
output "catalog_db_endpoint" {
  description = "Writer endpoint for the catalog database"
  value       = module.catalog_rds.cluster_endpoint
}

output "catalog_db_database_name" {
  description = "Database name for the catalog database"
  value       = module.catalog_rds.cluster_database_name
}

output "catalog_db_master_password" {
  description = "Master password for the catalog database"
  value       = module.catalog_rds.cluster_master_password
  sensitive   = true
}

output "catalog_db_master_username" {
  description = "Master username for the catalog database"
  value       = module.catalog_rds.cluster_master_username
  sensitive   = true
}

output "catalog_db_port" {
  description = "Port for the catalog database"
  value       = module.catalog_rds.cluster_port
}

# Orders Database
output "orders_db_endpoint" {
  description = "Writer endpoint for the orders database"
  value       = module.orders_rds.cluster_endpoint
}

output "orders_db_database_name" {
  description = "Database name for the orders database"
  value       = module.orders_rds.cluster_database_name
}

output "orders_db_master_password" {
  description = "Master password for the orders database"
  value       = module.orders_rds.cluster_master_password
  sensitive   = true
}

output "orders_db_master_username" {
  description = "Master username for the orders database"
  value       = module.orders_rds.cluster_master_username
  sensitive   = true
}

output "orders_db_port" {
  description = "Port for the orders database"
  value       = module.orders_rds.cluster_port
}

# DynamoDB Carts
output "carts_dynamodb_table_arn" {
  description = "ARN of the carts DynamoDB table"
  value       = module.dynamodb_carts.dynamodb_table_arn
}

output "carts_dynamodb_table_name" {
  description = "Name of the carts DynamoDB table"
  value       = module.dynamodb_carts.dynamodb_table_id
}

output "carts_dynamodb_policy_arn" {
  description = "ARN of IAM policy to access carts DynamoDB table"
  value       = aws_iam_policy.carts_dynamo.arn
}

output "carts_iam_role_arn" {
  description = "IAM role ARN for carts service (IRSA)"
  value       = module.iam_assumable_role_carts.iam_role_arn
}

# ElastiCache Redis
output "checkout_elasticache_endpoint" {
  value       = module.checkout_elasticache_redis.endpoint
  description = "Checkout Redis hostname"
}

output "checkout_elasticache_port" {
  value       = module.checkout_elasticache_redis.port
  description = "Checkout Redis port"
}

# Amazon SQS
output "orders_sqs_queue_url" {
  value       = aws_sqs_queue.orders.url
  description = "SQS queue URL for orders messaging"
}

output "orders_sqs_queue_arn" {
  value       = aws_sqs_queue.orders.arn
  description = "SQS queue ARN for orders messaging"
}

output "orders_sqs_queue_name" {
  value       = aws_sqs_queue.orders.name
  description = "SQS queue name for orders messaging"
}

output "orders_iam_role_arn" {
  description = "IAM role ARN for orders service (IRSA)"
  value       = module.iam_assumable_role_orders.iam_role_arn
}
