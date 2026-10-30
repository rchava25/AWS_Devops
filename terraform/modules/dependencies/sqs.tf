# =============================================================================
# ORDERS MESSAGE QUEUE (Amazon SQS)
# =============================================================================
# Replaces Amazon MQ (RabbitMQ) with SQS for simpler, faster provisioning.
# The retail store orders service supports SQS as a messaging provider natively.

resource "aws_sqs_queue" "orders" {
  name                       = "${var.environment_name}-orders"
  visibility_timeout_seconds = 30
  message_retention_seconds  = 345600 # 4 days
  receive_wait_time_seconds  = 10     # Long polling

  tags = var.tags
}
