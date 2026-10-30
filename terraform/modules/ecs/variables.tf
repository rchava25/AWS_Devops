variable "environment_name" {
  type        = string
  description = "Name of the environment"
}

variable "tags" {
  description = "List of tags to be associated with resources."
  default     = {}
  type        = any
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "subnet_ids" {
  description = "List of private subnet IDs."
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "List of public subnet IDs."
  type        = list(string)
}

variable "container_image_overrides" {
  type = object({
    default_repository = optional(string)
    default_tag        = optional(string)

    ui       = optional(string)
    catalog  = optional(string)
    cart     = optional(string)
    checkout = optional(string)
    orders   = optional(string)
  })
  default     = {}
  description = "Object that encapsulates any overrides to default values"
}


variable "catalog_db_endpoint" {
  type        = string
  description = "Endpoint of the catalog database"
}

variable "catalog_db_port" {
  type        = string
  description = "Port of the catalog database"
}

variable "catalog_db_name" {
  type        = string
  description = "Name of the catalog database"
}

variable "catalog_db_username" {
  type        = string
  description = "Username for the catalog database"
}

variable "catalog_db_password" {
  type        = string
  description = "Password for the catalog database"
}

variable "carts_dynamodb_table_name" {
  type        = string
  description = "DynamoDB table name for the carts service"
}

variable "carts_dynamodb_policy_arn" {
  type        = string
  description = "IAM policy for DynamoDB table for the carts service"
}

variable "orders_db_endpoint" {
  type        = string
  description = "Endpoint of the orders database"
}

variable "orders_db_port" {
  type        = string
  description = "Port of the orders database"
}

variable "orders_db_name" {
  type        = string
  description = "Name of the orders database"
}

variable "orders_db_username" {
  type        = string
  description = "Username for the orders database"
}

variable "orders_db_password" {
  type        = string
  description = "Username for the password database"
}

variable "checkout_redis_endpoint" {
  type        = string
  description = "Endpoint of the checkout redis"
}

variable "checkout_redis_port" {
  type        = string
  description = "Port of the checkout redis"
}

variable "orders_sqs_queue_name" {
  type        = string
  description = "SQS queue name for orders messaging"
}

variable "orders_sqs_queue_arn" {
  type        = string
  description = "SQS queue ARN for orders messaging"
}

variable "opentelemetry_enabled" {
  type        = bool
  default     = false
  description = "Enable OpenTelemetry instrumentation"
}

variable "container_insights_setting" {
  type        = string
  default     = "enhanced"
  description = "Container Insights setting for ECS cluster (enhanced or disabled)"

  validation {
    condition     = contains(["enhanced", "disabled"], var.container_insights_setting)
    error_message = "container_insights_setting must be either 'enhanced' or 'disabled'"
  }
}

variable "lifecycle_events_enabled" {
  type        = bool
  default     = false
  description = "Enable ECS lifecycle events to CloudWatch Logs"
}

# -----------------------------------------------------------------------------
# Observability Variables
# -----------------------------------------------------------------------------

variable "log_retention_days" {
  type        = number
  default     = 30
  description = "CloudWatch Logs retention period in days"

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a valid CloudWatch Logs retention value"
  }
}

variable "logs_kms_key_arn" {
  type        = string
  default     = null
  description = "KMS key ARN for encrypting CloudWatch Logs (optional)"
}

variable "alb_access_logs_enabled" {
  type        = bool
  default     = false
  description = "Enable ALB access logs to S3"
}

variable "alb_logs_retention_days" {
  type        = number
  default     = 30
  description = "S3 lifecycle expiration for ALB access logs"
}

variable "vpc_flow_logs_enabled" {
  type        = bool
  default     = false
  description = "Enable VPC Flow Logs to CloudWatch Logs"
}

variable "cloudwatch_alarms_enabled" {
  type        = bool
  default     = true
  description = "Enable CloudWatch alarms for ECS services and ALB"
}

variable "alarm_sns_topic_arn" {
  type        = string
  default     = null
  description = "SNS topic ARN for CloudWatch alarm notifications"
}

# -----------------------------------------------------------------------------
# Pre-created Security Group IDs (to avoid circular dependencies)
# -----------------------------------------------------------------------------

variable "catalog_security_group_id" {
  type        = string
  description = "Pre-created security group ID for catalog service"
}

variable "carts_security_group_id" {
  type        = string
  description = "Pre-created security group ID for carts service"
}

variable "checkout_security_group_id" {
  type        = string
  description = "Pre-created security group ID for checkout service"
}

variable "orders_security_group_id" {
  type        = string
  description = "Pre-created security group ID for orders service"
}

variable "ui_security_group_id" {
  type        = string
  description = "Pre-created security group ID for ui service"
}

# -----------------------------------------------------------------------------
# ALB Configuration Variables
# -----------------------------------------------------------------------------

variable "alb_ingress_cidr_blocks" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "CIDR blocks allowed to access the ALB"
}

variable "alb_backend_port" {
  type        = number
  default     = 8080
  description = "Backend port for ALB target group"
}

variable "alb_health_check_path" {
  type        = string
  default     = "/actuator/health"
  description = "Health check path for ALB target group"
}

variable "alb_health_check_interval" {
  type        = number
  default     = 30
  description = "Health check interval in seconds"
}

variable "alb_healthy_threshold" {
  type        = number
  default     = 2
  description = "Number of consecutive health checks successes required"
}

variable "alb_unhealthy_threshold" {
  type        = number
  default     = 3
  description = "Number of consecutive health check failures required"
}

variable "alb_health_check_timeout" {
  type        = number
  default     = 5
  description = "Health check timeout in seconds"
}

variable "alb_deregistration_delay" {
  type        = number
  default     = 30
  description = "Deregistration delay in seconds"
}

# -----------------------------------------------------------------------------
# CloudWatch Alarm Threshold Variables
# -----------------------------------------------------------------------------

variable "cpu_alarm_threshold" {
  type        = number
  default     = 80
  description = "CPU utilization threshold for CloudWatch alarms (percentage)"
}

variable "memory_alarm_threshold" {
  type        = number
  default     = 80
  description = "Memory utilization threshold for CloudWatch alarms (percentage)"
}

variable "error_count_threshold" {
  type        = number
  default     = 50
  description = "Error count threshold for log-based CloudWatch alarms"
}

variable "latency_threshold" {
  type        = number
  default     = 2
  description = "ALB p95 latency threshold in seconds"
}

variable "http_5xx_threshold" {
  type        = number
  default     = 10
  description = "HTTP 5XX error count threshold for CloudWatch alarms"
}
