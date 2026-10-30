# =============================================================================
# ORDERS MESSAGE QUEUE (Amazon SQS) - EKS Specific
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

# IAM role for orders service to access SQS (IRSA)
data "aws_iam_policy_document" "orders_sqs" {
  statement {
    actions = [
      "sqs:SendMessage",
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
    ]
    resources = [aws_sqs_queue.orders.arn]
  }
}

resource "aws_iam_policy" "orders_sqs" {
  name   = "${var.environment_name}-orders-sqs"
  policy = data.aws_iam_policy_document.orders_sqs.json
  tags   = var.tags
}

module "iam_assumable_role_orders" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "~> 5.39"

  create_role                   = true
  role_name                     = "${var.environment_name}-orders"
  provider_url                  = var.eks_oidc_provider
  role_policy_arns              = [aws_iam_policy.orders_sqs.arn]
  oidc_fully_qualified_subjects = ["system:serviceaccount:orders:orders"]

  tags = var.tags
}
