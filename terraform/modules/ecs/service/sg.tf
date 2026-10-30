# Security group is always provided from the parent module
# This avoids circular dependency issues

locals {
  security_group_id = var.security_group_id
}
