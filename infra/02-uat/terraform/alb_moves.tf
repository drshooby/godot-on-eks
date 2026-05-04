# Remap Terraform state after renaming ingress edge resources (*traefik* → *ingress*).
# Updating the AWS target group `name` still forces TG replacement — `moved` only
# rewrites addresses in state before diffing.

moved {
  from = aws_lb_target_group.traefik
  to   = aws_lb_target_group.ingress
}

moved {
  from = aws_autoscaling_attachment.nodes_to_traefik
  to   = aws_autoscaling_attachment.nodes_to_ingress
}
