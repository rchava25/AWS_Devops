# Security Groups Module - Main
# Shared security groups for ECS and EKS services
# Created at module level to avoid circular dependencies between ECS/EKS and dependencies modules

resource "aws_security_group" "catalog" {
  name        = "${var.environment_name}-catalog-task"
  description = "Security group for catalog service tasks"
  vpc_id      = var.vpc_id

  ingress {
    description = "Allow inbound HTTP API traffic"
    protocol    = "tcp"
    from_port   = 8080
    to_port     = 8080
    cidr_blocks = [var.vpc_cidr_block]
  }

  # EKS-specific: Istio healthcheck ports
  dynamic "ingress" {
    for_each = var.enable_eks_rules ? [1] : []
    content {
      description = "Allow inbound Istio healthchecks"
      from_port   = 15020
      to_port     = 15021
      protocol    = "tcp"
      cidr_blocks = [var.vpc_cidr_block]
    }
  }

  egress {
    description = "Allow all egress"
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.environment_name}-catalog-task"
  })
}


resource "aws_security_group" "carts" {
  name        = "${var.environment_name}-carts-task"
  description = "Security group for carts service tasks"
  vpc_id      = var.vpc_id

  ingress {
    description = "Allow inbound HTTP API traffic"
    protocol    = "tcp"
    from_port   = 8080
    to_port     = 8080
    cidr_blocks = [var.vpc_cidr_block]
  }

  # EKS-specific: Istio healthcheck ports
  dynamic "ingress" {
    for_each = var.enable_eks_rules ? [1] : []
    content {
      description = "Allow inbound Istio healthchecks"
      from_port   = 15020
      to_port     = 15021
      protocol    = "tcp"
      cidr_blocks = [var.vpc_cidr_block]
    }
  }

  egress {
    description = "Allow all egress"
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.environment_name}-carts-task"
  })
}

resource "aws_security_group" "checkout" {
  name        = "${var.environment_name}-checkout-task"
  description = "Security group for checkout service tasks"
  vpc_id      = var.vpc_id

  ingress {
    description = "Allow inbound HTTP API traffic"
    protocol    = "tcp"
    from_port   = 8080
    to_port     = 8080
    cidr_blocks = [var.vpc_cidr_block]
  }

  # EKS-specific: Istio healthcheck ports
  dynamic "ingress" {
    for_each = var.enable_eks_rules ? [1] : []
    content {
      description = "Allow inbound Istio healthchecks"
      from_port   = 15020
      to_port     = 15021
      protocol    = "tcp"
      cidr_blocks = [var.vpc_cidr_block]
    }
  }

  egress {
    description = "Allow all egress"
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.environment_name}-checkout-task"
  })
}


resource "aws_security_group" "orders" {
  name        = "${var.environment_name}-orders-task"
  description = "Security group for orders service tasks"
  vpc_id      = var.vpc_id

  ingress {
    description = "Allow inbound HTTP API traffic"
    protocol    = "tcp"
    from_port   = 8080
    to_port     = 8080
    cidr_blocks = [var.vpc_cidr_block]
  }

  # EKS-specific: Istio healthcheck ports
  dynamic "ingress" {
    for_each = var.enable_eks_rules ? [1] : []
    content {
      description = "Allow inbound Istio healthchecks"
      from_port   = 15020
      to_port     = 15021
      protocol    = "tcp"
      cidr_blocks = [var.vpc_cidr_block]
    }
  }

  egress {
    description = "Allow all egress"
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.environment_name}-orders-task"
  })
}

resource "aws_security_group" "ui" {
  name        = "${var.environment_name}-ui-task"
  description = "Security group for UI service tasks"
  vpc_id      = var.vpc_id

  ingress {
    description = "Allow inbound HTTP API traffic"
    protocol    = "tcp"
    from_port   = 8080
    to_port     = 8080
    cidr_blocks = [var.vpc_cidr_block]
  }

  # EKS-specific: Istio healthcheck ports
  dynamic "ingress" {
    for_each = var.enable_eks_rules ? [1] : []
    content {
      description = "Allow inbound Istio healthchecks"
      from_port   = 15020
      to_port     = 15021
      protocol    = "tcp"
      cidr_blocks = [var.vpc_cidr_block]
    }
  }

  egress {
    description = "Allow all egress"
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.environment_name}-ui-task"
  })
}
