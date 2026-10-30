# =============================================================================
# Unified DevOps Agent Workshop - Root Variables
# =============================================================================
# This file defines all input variables for the unified workshop infrastructure.
# Variables are organized by category: general, VPC, ECS, EKS, and observability.
# =============================================================================

# -----------------------------------------------------------------------------
# GENERAL CONFIGURATION
# -----------------------------------------------------------------------------

variable "environment_name" {
  description = "Name of the workshop environment (used for resource naming and tagging)"
  type        = string
  default     = "devops-agent-workshop"
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}

# -----------------------------------------------------------------------------
# VPC CONFIGURATION
# -----------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "enable_vpc_flow_logs" {
  description = "Enable VPC flow logs for network observability"
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# PLATFORM ENABLEMENT FLAGS
# -----------------------------------------------------------------------------

variable "enable_ecs" {
  description = "Enable ECS cluster and services deployment"
  type        = bool
  default     = true
}

variable "enable_eks" {
  description = "Enable EKS cluster and workloads deployment"
  type        = bool
  default     = true
}

variable "enable_crm" {
  description = "Enable CRM application deployment (serverless stack via CDK)"
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# CRM CONFIGURATION
# -----------------------------------------------------------------------------

variable "crm_app_path" {
  description = "Absolute path to the external devops-agent-demo-ws/ directory containing the CRM CDK app (legacy; unused now that the CRM deploy runs in its own CodeBuild from S3)"
  type        = string
  default     = ""
}

variable "crm_app_s3_url" {
  description = "s3:// URL of the CRM app bundle (devops-agent-demo-ws.zip). Passed to the dedicated CRM CodeBuild for async deployment."
  type        = string
  default     = ""
}

variable "crm_workshop_username" {
  description = "Default Cognito username for CRM password-only login"
  type        = string
  default     = "workshop-user@example.com"
}

variable "crm_devops_agent_webhook_url" {
  description = "DevOps Agent webhook endpoint URL for CRM alarm integration"
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# ECS CLUSTER CONFIGURATION
# -----------------------------------------------------------------------------

variable "ecs_cluster_name" {
  description = "Name of the ECS cluster"
  type        = string
  default     = "retail-store-ecs-cluster"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]*$", var.ecs_cluster_name)) && length(var.ecs_cluster_name) <= 255
    error_message = "ECS cluster name must start with a letter, contain only alphanumeric characters and hyphens, and be 255 characters or less."
  }
}

# -----------------------------------------------------------------------------
# CONTAINER IMAGE CONFIGURATION (Shared)
# -----------------------------------------------------------------------------

variable "container_image_overrides" {
  description = "Container image overrides for retail store services"
  type = object({
    default_repository = optional(string)
    default_tag        = optional(string)
    ui                 = optional(string)
    catalog            = optional(string)
    cart               = optional(string)
    checkout           = optional(string)
    orders             = optional(string)
  })
  default = {}
}

# -----------------------------------------------------------------------------
# ECS CONFIGURATION
# -----------------------------------------------------------------------------

variable "ecs_opentelemetry_enabled" {
  description = "Enable OpenTelemetry instrumentation for ECS services"
  type        = bool
  default     = false
}

variable "ecs_container_insights_setting" {
  description = "Container Insights setting for ECS cluster"
  type        = string
  default     = "enhanced"

  validation {
    condition     = contains(["enhanced", "disabled"], var.ecs_container_insights_setting)
    error_message = "ecs_container_insights_setting must be either 'enhanced' or 'disabled'"
  }
}

# -----------------------------------------------------------------------------
# EKS CONFIGURATION
# -----------------------------------------------------------------------------

variable "eks_cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "devops-agent-eks"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]*$", var.eks_cluster_name)) && length(var.eks_cluster_name) <= 40
    error_message = "Cluster name must start with a letter, contain only alphanumeric characters and hyphens, and be 40 characters or less."
  }
}

variable "kubernetes_version" {
  description = "Kubernetes version for EKS cluster"
  type        = string
  default     = "1.34"

  validation {
    condition     = contains(["1.31", "1.32", "1.33", "1.34"], var.kubernetes_version)
    error_message = "Kubernetes version must be a supported EKS version: 1.31, 1.32, 1.33, or 1.34."
  }
}

variable "eks_node_pools" {
  description = "EKS Auto Mode node pools to enable"
  type        = list(string)
  default     = ["system", "general-purpose"]
}

variable "eks_istio_enabled" {
  description = "Enable Istio service mesh for EKS"
  type        = bool
  default     = false
}

variable "eks_opentelemetry_enabled" {
  description = "Enable OpenTelemetry (ADOT) for EKS"
  type        = bool
  default     = false
}

variable "eks_application_signals_enabled" {
  description = "Enable CloudWatch Application Signals auto-instrumentation for EKS"
  type        = bool
  default     = true
}

variable "eks_enable_grafana" {
  description = "Enable Amazon Managed Grafana (requires AWS SSO). Mutually exclusive with enable_amg_keycloak_idp — when the latter is on, AMG is owned by that module and uses Keycloak SAML instead of AWS SSO."
  type        = bool
  default     = false
}

variable "eks_deploy_retail_app" {
  description = "Deploy the retail store application to EKS"
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# AMG + Keycloak SAML IdP + AMP (open-source observability)
# -----------------------------------------------------------------------------

variable "enable_amg_keycloak_idp" {
  description = "Provision AMP, AMG (with Keycloak SAML), and an AMP managed scraper for the EKS cluster. Requires enable_eks=true."
  type        = bool
  default     = true
}

variable "amg_keycloak_idp_name" {
  description = "Name prefix for the AMG/Keycloak/AMP module resources"
  type        = string
  default     = "oss-observability"
}

variable "amg_keycloak_realm_name" {
  description = "Keycloak realm to use for AMG SAML"
  type        = string
  default     = "amg"
}

# -----------------------------------------------------------------------------
# OBSERVABILITY CONFIGURATION (Shared)
# -----------------------------------------------------------------------------

variable "log_retention_days" {
  description = "CloudWatch Logs retention period in days"
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a valid CloudWatch Logs retention value"
  }
}

variable "cloudwatch_alarms_enabled" {
  description = "Enable CloudWatch alarms for services and infrastructure"
  type        = bool
  default     = true
}

variable "alarm_sns_topic_arn" {
  description = "SNS topic ARN for CloudWatch alarm notifications (optional)"
  type        = string
  default     = null
}
