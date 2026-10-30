# Security Groups Module - Outputs

output "catalog_id" {
  description = "Security group ID for catalog service"
  value       = aws_security_group.catalog.id
}

output "carts_id" {
  description = "Security group ID for carts service"
  value       = aws_security_group.carts.id
}

output "checkout_id" {
  description = "Security group ID for checkout service"
  value       = aws_security_group.checkout.id
}

output "orders_id" {
  description = "Security group ID for orders service"
  value       = aws_security_group.orders.id
}

output "ui_id" {
  description = "Security group ID for UI service"
  value       = aws_security_group.ui.id
}

# Additional outputs for convenience
output "all_service_security_group_ids" {
  description = "List of all service security group IDs"
  value = [
    aws_security_group.catalog.id,
    aws_security_group.carts.id,
    aws_security_group.checkout.id,
    aws_security_group.orders.id,
    aws_security_group.ui.id
  ]
}
