# =============================================================================
# CRM Orchestrator Module - Input Variables
# =============================================================================
# Variables for the CRM CDK deployment orchestration module.
# This module deploys the external CRM app into the shared workshop VPC.
# =============================================================================

variable "environment_name" {
  description = "Workshop environment name prefix"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID from shared VPC module"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for CRM Lambda and RDS placement"
  type        = list(string)
}

variable "region" {
  description = "AWS region for CDK deployment"
  type        = string
}

variable "crm_app_path" {
  description = "Absolute path to the external devops-agent-demo-ws/ directory (legacy; unused when crm_app_s3_url is set and the CRM deploy runs in its own CodeBuild)"
  type        = string
  default     = ""
}

variable "crm_app_s3_url" {
  description = "s3:// URL of the CRM app bundle (devops-agent-demo-ws.zip). The dedicated CRM CodeBuild downloads and deploys it asynchronously, off the CloudFormation-blocking path."
  type        = string
  default     = ""
}

variable "devops_agent_webhook_url" {
  description = "DevOps Agent webhook endpoint URL"
  type        = string
  default     = ""
}

variable "workshop_username" {
  description = "Default Cognito username for password-only login"
  type        = string
  default     = "workshop-user@example.com"
}

variable "tags" {
  description = "Resource tags"
  type        = map(string)
}
