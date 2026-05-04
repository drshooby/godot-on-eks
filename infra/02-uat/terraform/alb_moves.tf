# `moved` addresses below are legacy Terraform resource names from before the
# ALB target group was renamed to *ingress*; do not change `from` — they must
# match addresses already in state.

moved {
  from = aws_lb_target_group.traefik
  to   = aws_lb_target_group.ingress
}

moved {
  from = aws_autoscaling_attachment.nodes_to_traefik
  to   = aws_autoscaling_attachment.nodes_to_ingress
}
