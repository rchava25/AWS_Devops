# EKS Module Variables
# Input variables for the EKS cluster module

# =============================================================================
# REQUIRED VARIABLES
# =============================================================================

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]*$", var.cluster_name)) && length(var.cluster_name) <= 40
    error_message = "Cluster name must start with a letter, contain only alphanumeric characters and hyphens, and be 40 characters or less."
  }
}

variable "environment_name" {
  description = "Name of the workshop environment (used for tagging)"
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC where EKS cluster will be deployed"
  type        = string
}

variable "private_subnets" {
  description = "List of private subnet IDs for EKS nodes"
  type        = list(string)
}

variable "public_subnets" {
  description = "List of public subnet IDs for load balancers"
  type        = list(string)
}

# =============================================================================
# EKS CONFIGURATION
# =============================================================================

variable "kubernetes_version" {
  description = "Kubernetes version for EKS cluster"
  type        = string
  default     = "1.34"

  validation {
    condition     = contains(["1.31", "1.32", "1.33", "1.34"], var.kubernetes_version)
    error_message = "Kubernetes version must be a supported EKS version: 1.31, 1.32, 1.33, or 1.34."
  }
}

variable "node_pools" {
  description = "EKS Auto Mode node pools"
  type        = list(string)
  default     = ["system", "general-purpose"]
}

# =============================================================================
# OPTIONAL FEATURE FLAGS
# =============================================================================

variable "istio_enabled" {
  description = "Boolean value that enables Istio"
  type        = bool
  default     = false
}

variable "opentelemetry_enabled" {
  description = "Boolean value that enables OpenTelemetry (ADOT)"
  type        = bool
  default     = false
}

variable "application_signals_enabled" {
  description = "Boolean value that enables CloudWatch Application Signals auto-instrumentation"
  type        = bool
  default     = true
}

variable "enable_grafana" {
  description = "Boolean value that enables Amazon Managed Grafana. Requires AWS SSO to be configured in the account."
  type        = bool
  default     = false
}

variable "deploy_retail_app" {
  description = "Whether to deploy the retail store application components"
  type        = bool
  default     = true
}

# =============================================================================
# CONTAINER IMAGE OVERRIDES
# =============================================================================

variable "container_image_overrides" {
  type = object({
    default_repository = optional(string)
    default_tag        = optional(string)
    ui                 = optional(string)
    catalog            = optional(string)
    cart               = optional(string)
    checkout           = optional(string)
    orders             = optional(string)
  })
  default     = {}
  description = "Object that encapsulates any overrides to default container image values"
}

# =============================================================================
# TAGS
# =============================================================================

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
