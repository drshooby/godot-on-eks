resource "aws_security_group" "rds_access" {
  name        = "uat-rds-from-eks"
  description = "MySQL from EKS nodes"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "MySQL from EKS node SG"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "uat-rds-from-eks" })
}

module "db" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.0"

  identifier = "godot-uat-mysql"

  engine               = "mysql"
  engine_version       = "8.0"
  family               = "mysql8.0"
  major_engine_version = "8.0"

  instance_class        = var.db_instance_class
  allocated_storage     = var.db_allocated_storage
  storage_encrypted     = true
  deletion_protection   = false
  skip_final_snapshot   = true
  copy_tags_to_snapshot = true

  db_name  = "uatdb"
  username = "dbmaster"

  manage_master_user_password = true

  port = 3306

  vpc_security_group_ids = [aws_security_group.rds_access.id]

  subnet_ids             = module.vpc.private_subnets
  create_db_subnet_group = true
  multi_az               = false

  tags = var.tags
}
