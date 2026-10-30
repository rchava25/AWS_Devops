# =============================================================================
# EKS Dependencies Module - Variables
# =============================================================================

variable "environment_name" {
  type        = string
  description = "Name of the environment (used for resource naming)"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID for the resources"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block of the VPC (used for security group rules)"
}

variable "subnet_ids" {
  description = "List of private subnet IDs for database subnet groups"
  type        = list(string)
}

variable "eks_cluster_security_group_id" {
  type        = string
  description = "Security group ID of the EKS cluster (for allowing access to dependencies)"
}

variable "eks_oidc_provider" {
  type        = string
  description = "OIDC provider URL for the EKS cluster (without https://)"
}

variable "tags" {
  description = "Tags to apply to all resources"
  default     = {}
  type        = map(string)
}
