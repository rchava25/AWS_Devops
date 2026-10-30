# =============================================================================
# CARTS TABLE (DynamoDB) - EKS Specific
# =============================================================================

module "dynamodb_carts" {
  source  = "terraform-aws-modules/dynamodb-table/aws"
  version = "3.3.0"

  name     = "${var.environment_name}-carts"
  hash_key = "id"

  attributes = [
    {
      name = "id"
      type = "S"
    },
    {
      name = "customerId"
      type = "S"
    }
  ]

  global_secondary_indexes = [
    {
      name            = "idx_global_customerId"
      hash_key        = "customerId"
      projection_type = "ALL"
    }
  ]

  tags = var.tags
}

resource "aws_iam_policy" "carts_dynamo" {
  name        = "${var.environment_name}-carts-dynamo"
  path        = "/"
  description = "DynamoDB policy for carts application"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllAPIActionsOnCart"
        Effect = "Allow"
        Action = "dynamodb:*"
        Resource = [
          module.dynamodb_carts.dynamodb_table_arn,
          "${module.dynamodb_carts.dynamodb_table_arn}/index/*"
        ]
      }
    ]
  })

  tags = var.tags
}

# IAM Role for Carts service (IRSA)
module "iam_assumable_role_carts" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "~> 5.0"

  create_role                   = true
  role_name                     = "${var.environment_name}-carts"
  provider_url                  = var.eks_oidc_provider
  role_policy_arns              = [aws_iam_policy.carts_dynamo.arn]
  oidc_fully_qualified_subjects = ["system:serviceaccount:carts:carts"]

  tags = var.tags
}
