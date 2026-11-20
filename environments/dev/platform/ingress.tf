resource "aws_security_group" "alb" {
  count       = var.enable_alb ? 1 : 0
  name_prefix = "${var.name_prefix}-alb-"
  description = "HTTPS ingress to Gateway only"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name_prefix}-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  for_each          = var.enable_alb ? toset(var.alb_ingress_cidrs) : toset([])
  security_group_id = aws_security_group.alb[0].id
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_lb" "gateway" {
  count              = var.enable_alb ? 1 : 0
  name               = "${var.name_prefix}-gateway"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb[0].id]
  subnets            = var.public_subnet_ids
}

resource "aws_lb_target_group" "gateway" {
  count       = var.enable_alb ? 1 : 0
  name        = "${var.name_prefix}-gateway"
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id
  health_check {
    enabled             = true
    protocol            = "HTTP"
    port                = "9091"
    path                = var.gateway_readiness_path
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

variable "gateway_readiness_path" {
  type        = string
  description = "Verified Gateway readiness path on management port 9091."
  default     = null
  validation {
    condition     = !var.enable_alb || (var.gateway_readiness_path == null ? false : startswith(var.gateway_readiness_path, "/"))
    error_message = "Gateway readiness path must be absolute."
  }
}

resource "aws_lb_listener" "https" {
  count             = var.enable_alb ? 1 : 0
  load_balancer_arn = aws_lb.gateway[0].arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.gateway[0].arn
  }
}

output "gateway_target_group_arn" {
  value = var.enable_alb ? aws_lb_target_group.gateway[0].arn : null
}


moved {
  from = aws_security_group.alb
  to   = aws_security_group.alb[0]
}
moved {
  from = aws_lb.gateway
  to   = aws_lb.gateway[0]
}
moved {
  from = aws_lb_target_group.gateway
  to   = aws_lb_target_group.gateway[0]
}
moved {
  from = aws_lb_listener.https
  to   = aws_lb_listener.https[0]
}
