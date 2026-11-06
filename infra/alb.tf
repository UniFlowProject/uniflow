# Internal Application Load Balancer: the single private entry point behind the API Gateway VPC link.

resource "aws_security_group" "alb" {
  name        = "${var.project-tag}-alb-sg"
  description = "Internal ALB reachable only from the API Gateway VPC link"
  vpc_id      = aws_vpc.uniflow_vpc.id

  tags = {
    Name = "${var.project-tag}-alb-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_vpc_link" {
  security_group_id            = aws_security_group.alb.id
  description                  = "HTTP from the API Gateway VPC link"
  referenced_security_group_id = aws_security_group.vpc_link.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

resource "aws_vpc_security_group_egress_rule" "alb_to_vpc" {
  security_group_id = aws_security_group.alb.id
  description       = "Traffic to service tasks inside the VPC"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "-1"
}

resource "aws_lb" "internal" {
  name               = "${var.project-tag}-internal-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [for s in aws_subnet.private_app : s.id]

  enable_deletion_protection = false

  tags = {
    Name = "${var.project-tag}-internal-alb"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "application/json"
      message_body = "{\"message\":\"Not Found\"}"
      status_code  = "404"
    }
  }

}

# The ECS service in academic.tf registers its tasks
# in this target group (IP targets, Fargate awsvpc).
resource "aws_lb_target_group" "academic" {
  name                 = "${var.project-tag}-academic-tg"
  port                 = 3001
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = aws_vpc.uniflow_vpc.id
  deregistration_delay = 30

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name = "${var.project-tag}-academic-tg"
  }
}

# API Gateway strips the /api/academic[/v2] prefix, so the ALB sees /health,
# /periods, /courses, ...; everything goes to the academic service for now.
resource "aws_lb_listener_rule" "academic" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.academic.arn
  }

  condition {
    path_pattern {
      values = ["/*"]
    }
  }

}
