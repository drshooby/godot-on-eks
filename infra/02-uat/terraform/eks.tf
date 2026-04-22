module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = var.uat_cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    primary = {
      instance_types = ["t3.medium"]
      min_size       = 2
      max_size       = 4
      desired_size   = 2

      additional_security_group_rules = {
        allow_all_node_to_node = {
          description              = "Allow all traffic between nodes in the same SG"
          protocol                 = "-1"
          from_port                = 0
          to_port                  = 0
          type                     = "ingress"
          source_security_group_id = "self"
        }
      }
    }
  }

  tags = var.tags
}
