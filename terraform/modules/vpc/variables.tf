# VPC Module Variables

variable "environment_name" {
  type        = string
  description = "Name of the environment"
}

variable "vpc_cidr" {
  type        = string
  default     = "10.0.0.0/16"
  description = "CIDR block for the VPC"
}

variable "azs" {
  type        = list(string)
  description = "List of availability zones to use"
}

variable "public_subnet_tags" {
  type        = map(any)
  default     = {}
  description = "Additional tags to apply to public subnets"
}

variable "private_subnet_tags" {
  type        = map(any)
  default     = {}
  description = "Additional tags to apply to private subnets"
}

variable "tags" {
  description = "Tags to be associated with resources"
  default     = {}
  type        = map(string)
}

# EKS-specific variables
variable "enable_eks" {
  type        = bool
  default     = false
  description = "Enable EKS-specific subnet tags for load balancer integration"
}

variable "eks_cluster_name" {
  type        = string
  default     = ""
  description = "Name of the EKS cluster (required when enable_eks is true)"
}

# Flow logs configuration
variable "enable_flow_logs" {
  type        = bool
  default     = true
  description = "Enable VPC flow logs for network observability"
}
