module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = var.uat_cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # EKS Pod Identity agent — preferred over IRSA (no OIDC round-trip, simpler trust policy).
  # The old OIDC provider stays provisioned (module default) so existing IRSA roles keep
  # working during migration; remove once all workloads are on Pod Identity.
  cluster_addons = {
    eks-pod-identity-agent = {
      most_recent = true
    }
  }

  eks_managed_node_groups = {
    primary = {
      instance_types = ["t3.large"]
      min_size       = 2
      max_size       = 2
      desired_size   = 2
    }
  }

  tags = var.tags
}
