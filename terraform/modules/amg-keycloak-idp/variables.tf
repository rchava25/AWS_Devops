# amg-keycloak-idp module — input variables

variable "name" {
  description = "Name prefix for resources"
  type        = string
  default     = "oss-observability"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,30}[a-z0-9]$", var.name))
    error_message = "name must be lowercase alphanumeric with hyphens, max 32 chars."
  }
}

variable "vpc_id" {
  description = "VPC ID where EKS lives and Keycloak/Aurora will run"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block of the VPC"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs (>=2 across AZs)"
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "At least 2 private subnets are required."
  }
}

variable "eks_cluster_name" {
  description = "Existing EKS cluster name"
  type        = string
}

variable "cluster_ready" {
  description = "Opaque token from the eks module (cluster_ready output) that is only resolved once the EKS cluster-admin access entry has propagated. Gates this module's Kubernetes-provider resources so they don't 403 on a freshly created cluster."
  type        = string
  default     = ""
}

variable "eks_cluster_security_group_id" {
  description = "EKS cluster (or node) SG that the AMP scraper SG ingresses to"
  type        = string
}

variable "eks_node_security_group_ids" {
  description = "Map of additional security group IDs attached to EKS nodes/pods (e.g. EKS-managed primary cluster SG and worker node SG). Each is opened for ingress from the AMP scraper SG so kube-state-metrics, node-exporter, and other pod-IP scrape targets are reachable. Map keys are descriptive names (e.g. \"primary\", \"node\"); values are the SG IDs (may be known only after apply)."
  type        = map(string)
  default     = {}
}

variable "kubernetes_version" {
  description = "Kubernetes version of the cluster (used to pin community add-on versions)"
  type        = string
}

variable "realm_name" {
  description = "Keycloak realm name"
  type        = string
  default     = "amg"
}

variable "db_admin_username" {
  description = "Aurora master username for Keycloak DB"
  type        = string
  default     = "dbAdmin"
}

variable "db_engine_version" {
  description = "Aurora PostgreSQL engine version"
  type        = string
  default     = "17.7"

  validation {
    condition     = contains(["16.11", "17.7"], var.db_engine_version)
    error_message = "db_engine_version must be 16.11 or 17.7."
  }
}

variable "db_port" {
  description = "Aurora port"
  type        = number
  default     = 5432
}

variable "db_name" {
  description = "Aurora initial database name"
  type        = string
  default     = "keycloak"
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = {}
}
