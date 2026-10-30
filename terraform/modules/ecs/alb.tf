module "alb_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 4.0"

  name        = "${var.environment_name}-ui"
  description = "UI ALB security group"
  vpc_id      = var.vpc_id

  ingress_rules       = ["http-80-tcp"]
  ingress_cidr_blocks = var.alb_ingress_cidr_blocks

  egress_rules       = ["all-all"]
  egress_cidr_blocks = ["0.0.0.0/0"]
}

module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 8.0"

  name = "${var.environment_name}-ui"

  load_balancer_type = "application"

  vpc_id          = var.vpc_id
  subnets         = var.public_subnet_ids
  security_groups = [module.alb_sg.security_group_id]

  http_tcp_listeners = [
    {
      port               = 80
      protocol           = "HTTP"
      target_group_index = 0
    }
  ]

  target_groups = [
    {
      name                 = "ui-application"
      backend_protocol     = "HTTP"
      backend_port         = var.alb_backend_port
      target_type          = "ip"
      deregistration_delay = var.alb_deregistration_delay
      health_check = {
        enabled             = true
        interval            = var.alb_health_check_interval
        path                = var.alb_health_check_path
        port                = "traffic-port"
        healthy_threshold   = var.alb_healthy_threshold
        unhealthy_threshold = var.alb_unhealthy_threshold
        timeout             = var.alb_health_check_timeout
        protocol            = "HTTP"
      }
    }
  ]
}
