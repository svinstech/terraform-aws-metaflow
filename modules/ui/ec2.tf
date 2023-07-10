resource "aws_security_group" "fargate_security_group" {
  name        = local.ui_backend_security_group_name
  description = "Security Group for Fargate which runs the UI Backend."
  vpc_id      = var.metaflow_vpc_id

  ingress {
    from_port       = 0
    to_port         = 0
    protocol        = -1
    security_groups = [aws_security_group.ui_lb_security_group.id]
  }

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = -1
    self        = true
    description = "Internal communication"
  }

  # egress to anywhere
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # all
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all external communication"
  }

  tags = merge(
    var.standard_tags,
    {
      Metaflow = "true"
    }
  )
}

resource "aws_security_group" "ui_lb_security_group" {
  name        = local.alb_security_group_name
  description = "Security Group for ALB"
  vpc_id      = var.metaflow_vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.ui_allow_list
    description = "Allow public HTTPS"
  }

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = -1
    self        = true
    description = "Internal communication"
  }

  # egress to anywhere
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # all
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all external communication"
  }

  tags = merge(
    var.standard_tags,
    {
      Metaflow = "true"
    }
  )
}

resource "aws_lb" "this" {
  name               = "${var.resource_prefix}alb${var.resource_suffix}"
  internal           = var.alb_internal
  load_balancer_type = "application"
  subnets            = [var.subnet1_id, var.subnet2_id]
  security_groups = [
    aws_security_group.ui_lb_security_group.id
  ]

  tags = var.standard_tags
}

resource "aws_lb_target_group" "ui_backend" {
  name        = format("%.32s", "${var.resource_prefix}ui-backend${var.resource_suffix}")
  port        = 8083
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.metaflow_vpc_id

  health_check {
    protocol            = "HTTP"
    port                = 8083
    path                = "/api/ping"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = var.standard_tags
}

resource "aws_lb_target_group" "ui_static" {
  name        = format("%.32s", "${var.resource_prefix}ui-static${var.resource_suffix}")
  port        = 3000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.metaflow_vpc_id
  tags        = var.standard_tags
}

resource "aws_lb_listener" "this" {
  load_balancer_arn = aws_lb.this.arn
  port              = "443"
  protocol          = "HTTPS"

  certificate_arn = var.certificate_arn

  dynamic "default_action" {
    for_each = local.default_actions

    content {
      type = lookup(default_action.value, "type", null)

      dynamic "authenticate_cognito" {
        for_each = length(keys(lookup(default_action.value, "authenticate_cognito", {}))) > 0 ? [lookup(default_action.value, "authenticate_cognito", {})] : []

        content {
          user_pool_arn       = lookup(authenticate_cognito.value, "user_pool_arn", null)
          user_pool_client_id = lookup(authenticate_cognito.value, "user_pool_client_id", null)
          user_pool_domain    = lookup(authenticate_cognito.value, "user_pool_domain", null)
        }
      }
    }
  }

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ui_static.id
  }
}

resource "aws_lb_listener_rule" "ui_backend" {
  listener_arn = aws_lb_listener.this.arn
  priority     = 1

  dynamic "action" {
    for_each = local.default_actions

    content {
      type = lookup(action.value, "type", null)

      dynamic "authenticate_cognito" {
        for_each = length(keys(lookup(action.value, "authenticate_cognito", {}))) > 0 ? [lookup(action.value, "authenticate_cognito", {})] : []

        content {
          user_pool_arn       = lookup(authenticate_cognito.value, "user_pool_arn", null)
          user_pool_client_id = lookup(authenticate_cognito.value, "user_pool_client_id", null)
          user_pool_domain    = lookup(authenticate_cognito.value, "user_pool_domain", null)
        }
      }
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ui_backend.arn
  }

  condition {
    path_pattern {
      values = ["/api/*"]
    }
  }
}
