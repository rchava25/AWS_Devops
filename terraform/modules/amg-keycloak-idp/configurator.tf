# Configurator Lambda — bootstraps Keycloak realm + AMG SAML + data sources

resource "aws_iam_role" "configurator" {
  name = "${var.name}-configurator"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "configurator_basic" {
  role       = aws_iam_role.configurator.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "configurator_vpc" {
  role       = aws_iam_role.configurator.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "configurator" {
  name = "secrets-and-grafana"
  role = aws_iam_role.configurator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.consolidated.arn
      },
      {
        Effect = "Allow"
        Action = [
          "grafana:UpdateWorkspaceAuthentication",
          "grafana:DescribeWorkspace",
          "grafana:DescribeWorkspaceAuthentication",
          "grafana:CreateWorkspaceServiceAccount",
          "grafana:CreateWorkspaceServiceAccountToken",
          "grafana:DeleteWorkspaceServiceAccount",
          "grafana:DeleteWorkspaceServiceAccountToken",
        ]
        Resource = "arn:aws:grafana:${local.region}:${data.aws_caller_identity.current.account_id}:/workspaces/${aws_grafana_workspace.this.id}*"
      },
    ]
  })
}

data "archive_file" "configurator" {
  type        = "zip"
  source_file = "${path.module}/files/configurator.py"
  output_path = "${path.module}/.build/configurator.zip"
}

resource "aws_lambda_function" "configurator" {
  function_name    = "${var.name}-configurator"
  role             = aws_iam_role.configurator.arn
  runtime          = "python3.12"
  handler          = "configurator.handler"
  filename         = data.archive_file.configurator.output_path
  source_code_hash = data.archive_file.configurator.output_base64sha256
  timeout          = 600

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.configurator_lambda.id]
  }

  environment {
    variables = {
      KEYCLOAK_INTERNAL_URL  = "http://${aws_lb.alb.dns_name}"
      KEYCLOAK_PUBLIC_URL    = "https://${aws_apigatewayv2_api.idp.id}.execute-api.${local.region}.amazonaws.com"
      CONSOLIDATED_SECRET    = aws_secretsmanager_secret.consolidated.arn
      REALM_NAME             = var.realm_name
      AMG_WORKSPACE_ID       = aws_grafana_workspace.this.id
      AMG_WORKSPACE_ENDPOINT = aws_grafana_workspace.this.endpoint
      AMP_QUERY_URL          = "https://aps-workspaces.${local.region}.amazonaws.com/workspaces/${aws_prometheus_workspace.this.id}"
      REGION                 = local.region
    }
  }

  tags = var.tags

  depends_on = [
    aws_iam_role_policy_attachment.configurator_basic,
    aws_iam_role_policy_attachment.configurator_vpc,
    aws_iam_role_policy.configurator,
  ]
}

resource "aws_lambda_invocation" "configure" {
  function_name = aws_lambda_function.configurator.function_name

  input = jsonencode({
    realm_name = var.realm_name
  })

  triggers = {
    realm = var.realm_name
    code  = data.archive_file.configurator.output_base64sha256
  }

  depends_on = [
    aws_ecs_service.keycloak,
    aws_apigatewayv2_route.idp,
    aws_secretsmanager_secret_version.consolidated,
  ]
}
