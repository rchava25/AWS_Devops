# Security Groups Module - Variables

variable "environment_name" {
  type        = string
  description = "Name of the environment"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID for the security groups"
}

variable "vpc_cidr_block" {
  type        = string
  description = "VPC CIDR block for internal traffic rules"
  default     = "0.0.0.0/0"
}

variable "enable_eks_rules" {
  type        = bool
  description = "Enable EKS-specific security group rules (e.g., Istio healthchecks)"
  default     = false
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = any
  default     = {}
}
