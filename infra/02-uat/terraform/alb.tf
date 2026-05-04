resource "aws_security_group" "alb" {
  name        = "${var.uat_cluster_name}-alb"
  description = "UAT ALB (public) → ingress-controller NodePort on EKS nodes"
  vpc_id      = module.vpc.vpc_id

  tags = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "Public HTTP (redirected to HTTPS)"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "Public HTTPS"
}

resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Allow all egress (to EKS nodes)"
}

# Let the ALB reach EKS nodes on the ingress-controller NodePort. EKS module
# manages the node SG; we add a targeted rule rather than loosening its
# defaults. Port is shared between Traefik and Kong (whichever is installed
# binds the same NodePort), so this rule is unchanged when switching.
resource "aws_vpc_security_group_ingress_rule" "nodes_from_alb" {
  security_group_id            = module.eks.node_security_group_id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.ingress_http_nodeport
  to_port                      = var.ingress_http_nodeport
  ip_protocol                  = "tcp"
  description                  = "ALB → ingress-controller NodePort"
}

resource "aws_lb" "uat" {
  name               = "${var.uat_cluster_name}-alb"
  load_balancer_type = "application"
  subnets            = module.vpc.public_subnets
  security_groups    = [aws_security_group.alb.id]
  idle_timeout       = 60

  tags = var.tags
}

resource "aws_lb_target_group" "traefik" {
  # Resource name and AWS target-group name kept as "<cluster>-traefik" for
  # state stability across the Kong-alternative migration. Logically this is
  # the ingress-controller target group (Traefik OR Kong) — see
  # var.ingress_controller and the ingress_target_group_name output.
  name        = "${var.uat_cluster_name}-traefik"
  port        = var.ingress_http_nodeport
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = module.vpc.vpc_id

  # Both Traefik and Kong return 404 for unknown Hosts but the port itself is
  # up — accept anything in 200-404 so the health check just verifies the
  # controller is listening.
  health_check {
    path                = "/"
    port                = "traffic-port"
    protocol            = "HTTP"
    matcher             = "200-404"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = var.tags
}

# Attach every EKS managed-node-group ASG to the target group so new nodes
# register automatically.
resource "aws_autoscaling_attachment" "nodes_to_traefik" {
  for_each = toset(module.eks.eks_managed_node_groups["primary"].node_group_autoscaling_group_names)

  autoscaling_group_name = each.value
  lb_target_group_arn    = aws_lb_target_group.traefik.arn
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.uat.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.uat.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.uat.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.traefik.arn
  }
}
