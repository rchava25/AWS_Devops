# Keycloak — secrets, ALB, ECS Fargate, HTTP API Gateway, Aurora

# -----------------------------------------------------------------------------
# Random passwords + secrets
# -----------------------------------------------------------------------------

resource "random_password" "keycloak_master" {
  length      = 24
  special     = false
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
}

resource "random_password" "keycloak_amg_admin" {
  length      = 24
  special     = false
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
}

resource "random_password" "keycloak_amg_editor" {
  length      = 24
  special     = false
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
}

resource "random_password" "db_admin" {
  length      = 32
  special     = false
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
}

resource "aws_secretsmanager_secret" "db_admin" {
  name                    = "${var.name}/idp/db/admin"
  recovery_window_in_days = 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "db_admin" {
  secret_id = aws_secretsmanager_secret.db_admin.id
  secret_string = jsonencode({
    username = var.db_admin_username
    password = random_password.db_admin.result
  })
}

resource "aws_secretsmanager_secret" "consolidated" {
  name                    = "${var.name}/oss-grafana-keycloak"
  recovery_window_in_days = 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "consolidated" {
  secret_id = aws_secretsmanager_secret.consolidated.id
  secret_string = jsonencode({
    "grafana.url"                    = "https://${aws_grafana_workspace.this.endpoint}"
    "grafana.workspace_id"           = aws_grafana_workspace.this.id
    "keycloak.url"                   = "https://${aws_apigatewayv2_api.idp.id}.execute-api.${local.region}.amazonaws.com"
    "keycloak.master_admin.username" = "admin"
    "keycloak.master_admin.password" = random_password.keycloak_master.result
    "keycloak.admin.username"        = "admin"
    "keycloak.admin.password"        = random_password.keycloak_amg_admin.result
    "keycloak.editor.username"       = "editor"
    "keycloak.editor.password"       = random_password.keycloak_amg_editor.result
  })
}

# -----------------------------------------------------------------------------
# Security groups
# -----------------------------------------------------------------------------

resource "aws_security_group" "vpc_link" {
  name        = "${var.name}-vpclink"
  description = "API Gateway VPC link"
  vpc_id      = var.vpc_id

  ingress {
    description = "VPC-internal HTTP from API Gateway VPC link"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name}-vpclink" })
}

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "Internal ALB for Keycloak"
  vpc_id      = var.vpc_id

  ingress {
    description     = "From VPC link"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.vpc_link.id]
  }

  # Inline (not a standalone aws_security_group_rule): this SG uses inline
  # rules, and Terraform forbids mixing inline + standalone rules on one SG.
  # The previous standalone alb_from_configurator_lambda rule was silently
  # REMOVED on every second apply (the buildspec's automatic retry), cutting
  # the configurator Lambda off from Keycloak -> 600s invocation timeout.
  ingress {
    description     = "Configurator Lambda to ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.configurator_lambda.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name}-alb" })
}

resource "aws_security_group" "fargate" {
  name        = "${var.name}-fargate"
  description = "Keycloak Fargate tasks"
  vpc_id      = var.vpc_id

  ingress {
    description     = "From ALB"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name}-fargate" })
}

resource "aws_security_group" "configurator_lambda" {
  name        = "${var.name}-configurator-lambda"
  description = "Configurator Lambda - talks to Keycloak via internal ALB"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name}-configurator-lambda" })
}

resource "aws_security_group" "aurora" {
  name        = "${var.name}-aurora"
  description = "Aurora for Keycloak"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Keycloak Fargate"
    from_port       = var.db_port
    to_port         = var.db_port
    protocol        = "tcp"
    security_groups = [aws_security_group.fargate.id]
  }

  tags = merge(var.tags, { Name = "${var.name}-aurora" })
}

# -----------------------------------------------------------------------------
# Aurora PostgreSQL serverless v2
# -----------------------------------------------------------------------------

resource "aws_db_subnet_group" "aurora" {
  name        = "${var.name}-aurora"
  description = "${var.name} Keycloak DB"
  subnet_ids  = var.private_subnet_ids
  tags        = var.tags
}

resource "aws_rds_cluster_parameter_group" "aurora" {
  name        = "${var.name}-aurora-cluster"
  family      = local.family
  description = "${var.name} cluster pg"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  tags = var.tags
}

resource "aws_db_parameter_group" "aurora" {
  name        = "${var.name}-aurora-instance"
  family      = local.family
  description = "${var.name} instance pg"

  parameter {
    name         = "shared_preload_libraries"
    value        = "auto_explain,pg_stat_statements,pg_hint_plan,pgaudit"
    apply_method = "pending-reboot"
  }

  tags = var.tags
}

resource "aws_iam_role" "rds_monitoring" {
  name = "${var.name}-rds-monitoring"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_rds_cluster" "aurora" {
  cluster_identifier = "${var.name}-aurora"
  engine             = "aurora-postgresql"
  # IAM DB auth enabled to satisfy CKV_AWS_162; Keycloak keeps using password auth.
  iam_database_authentication_enabled = true
  engine_version                      = var.db_engine_version
  database_name                       = var.db_name
  port                                = var.db_port
  master_username                     = var.db_admin_username
  master_password                     = random_password.db_admin.result
  db_subnet_group_name                = aws_db_subnet_group.aurora.name
  vpc_security_group_ids              = [aws_security_group.aurora.id]
  backup_retention_period             = 1
  db_cluster_parameter_group_name     = aws_rds_cluster_parameter_group.aurora.name
  storage_encrypted                   = true
  skip_final_snapshot                 = true

  serverlessv2_scaling_configuration {
    min_capacity = 1
    max_capacity = 4
  }

  tags = var.tags
}

resource "aws_rds_cluster_instance" "aurora_first" {
  identifier                   = "${var.name}-aurora-1"
  cluster_identifier           = aws_rds_cluster.aurora.id
  instance_class               = "db.serverless"
  engine                       = "aurora-postgresql"
  db_parameter_group_name      = aws_db_parameter_group.aurora.name
  ca_cert_identifier           = "rds-ca-rsa4096-g1"
  monitoring_interval          = 1
  monitoring_role_arn          = aws_iam_role.rds_monitoring.arn
  auto_minor_version_upgrade   = false
  publicly_accessible          = false
  performance_insights_enabled = false

  tags = var.tags
}

# -----------------------------------------------------------------------------
# ECS cluster + Keycloak service
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "keycloak" {
  name              = "/ecs/${var.name}-keycloak"
  retention_in_days = 14
  tags              = var.tags
}

resource "aws_iam_role" "task_execution" {
  name = "${var.name}-task-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "task_execution_managed" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "task_execution_secrets" {
  name = "secrets-and-logs"
  role = aws_iam_role.task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = [
          aws_secretsmanager_secret.consolidated.arn,
          aws_secretsmanager_secret.db_admin.arn,
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.keycloak.arn}:*"
      },
    ]
  })
}

resource "aws_iam_role" "task" {
  name = "${var.name}-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_ecs_cluster" "keycloak" {
  name = "${var.name}-keycloak"
  tags = var.tags
}

resource "aws_ecs_task_definition" "keycloak" {
  family                   = "${var.name}-keycloak"
  cpu                      = "2048"
  memory                   = "4096"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name = "keycloak"
    # Official upstream Keycloak image (Apache 2.0, actively maintained by the
    # Keycloak/CNCF project). Replaces the Bitnami image, which was removed from
    # ECR Public on 2026-06-10 and whose frozen bitnamilegacy fork (max 26.3.3)
    # had wrapper-script startup bugs.
    # https://www.keycloak.org/server/containers
    # The official image uses the upstream KC_* contract and does NOT auto-start,
    # so an explicit `start` command is required (see `command` below).
    image     = "quay.io/keycloak/keycloak:26.5.2"
    essential = true

    # The official image entrypoint is /opt/keycloak/bin/kc.sh. `start` runs in
    # production mode; since the image is not pre-built (`--optimized`), Keycloak
    # auto-builds from the KC_* env on first boot, then migrates the DB schema.
    command = ["start"]

    linuxParameters = {
      initProcessEnabled = true
    }

    portMappings = [{
      containerPort = 8080
      protocol      = "tcp"
    }]

    environment = [
      { name = "KC_BOOTSTRAP_ADMIN_USERNAME", value = "admin" },
      { name = "KC_HTTP_ENABLED", value = "true" },
      # Single-replica Fargate service (desired_count = 1), so use the local
      # cache. 'ispn' (the production default) would attempt JGroups cluster
      # discovery, which is unnecessary and adds startup risk here.
      { name = "KC_CACHE", value = "local" },
      { name = "KC_PROXY_HEADERS", value = "xforwarded" },
      { name = "KC_HOSTNAME_STRICT", value = "false" },
      { name = "KC_HOSTNAME", value = "https://${aws_apigatewayv2_api.idp.id}.execute-api.${local.region}.amazonaws.com" },
      # Aurora's cluster parameter group sets rds.force_ssl=1, so the JDBC
      # connection must negotiate TLS. sslmode=require encrypts without cert
      # verification, which works against the RDS-managed CA.
      { name = "KC_DB", value = "postgres" },
      { name = "KC_DB_URL", value = "jdbc:postgresql://${aws_rds_cluster.aurora.endpoint}:${var.db_port}/${var.db_name}?sslmode=require" },
      { name = "KC_DB_USERNAME", value = var.db_admin_username },
    ]

    secrets = [
      { name = "KC_BOOTSTRAP_ADMIN_PASSWORD", valueFrom = "${aws_secretsmanager_secret.consolidated.arn}:keycloak.master_admin.password::" },
      { name = "KC_DB_PASSWORD", valueFrom = "${aws_secretsmanager_secret.db_admin.arn}:password::" },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.keycloak.name
        awslogs-region        = local.region
        awslogs-stream-prefix = "keycloak"
      }
    }
  }])

  tags = var.tags
}

resource "aws_lb" "alb" {
  name               = "${var.name}-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.private_subnet_ids

  tags = var.tags
}

resource "aws_lb_target_group" "keycloak" {
  name                 = "${var.name}-tg"
  port                 = 8080
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = 30

  health_check {
    path                = "/"
    protocol            = "HTTP"
    interval            = 10
    healthy_threshold   = 3
    unhealthy_threshold = 3
    matcher             = "200,302"
  }

  tags = var.tags
}

resource "aws_lb_listener" "alb" {
  #checkov:skip=CKV_AWS_2:Internal-only ALB reached exclusively through the API Gateway VPC Link; workshop account has no ACM cert or domain
  #checkov:skip=CKV_AWS_103:Listener is HTTP by design (internal, behind VPC Link); TLS policy not applicable without HTTPS
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.keycloak.arn
  }
}

resource "aws_ecs_service" "keycloak" {
  name                               = "${var.name}-keycloak"
  cluster                            = aws_ecs_cluster.keycloak.id
  task_definition                    = aws_ecs_task_definition.keycloak.arn
  desired_count                      = 1
  launch_type                        = "FARGATE"
  enable_execute_command             = true
  health_check_grace_period_seconds  = 60
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.fargate.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.keycloak.arn
    container_name   = "keycloak"
    container_port   = 8080
  }

  depends_on = [
    aws_lb_listener.alb,
    aws_rds_cluster_instance.aurora_first,
  ]

  tags = var.tags
}

# -----------------------------------------------------------------------------
# HTTP API Gateway
# -----------------------------------------------------------------------------

resource "aws_apigatewayv2_api" "idp" {
  name          = "${var.name}-idp-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_credentials = false
    allow_headers     = ["*"]
    allow_methods     = ["*"]
    allow_origins     = ["*"]
    max_age           = 300
  }

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "idp_api_access" {
  name              = "/aws/apigateway/${var.name}-idp-api"
  retention_in_days = 7
  tags              = var.tags
}

resource "aws_apigatewayv2_stage" "idp" {
  api_id      = aws_apigatewayv2_api.idp.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.idp_api_access.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      sourceIp       = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
    })
  }

  tags = var.tags
}

resource "aws_apigatewayv2_vpc_link" "idp" {
  name               = "${var.name}-idp-vpc-link"
  security_group_ids = [aws_security_group.vpc_link.id]
  subnet_ids         = var.private_subnet_ids
  tags               = var.tags
}

resource "aws_apigatewayv2_integration" "idp" {
  api_id                 = aws_apigatewayv2_api.idp.id
  integration_type       = "HTTP_PROXY"
  integration_method     = "ANY"
  integration_uri        = aws_lb_listener.alb.arn
  connection_type        = "VPC_LINK"
  connection_id          = aws_apigatewayv2_vpc_link.idp.id
  payload_format_version = "1.0"
  timeout_milliseconds   = 30000
}

resource "aws_apigatewayv2_route" "idp" {
  api_id    = aws_apigatewayv2_api.idp.id
  route_key = "ANY /{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.idp.id}"
}
