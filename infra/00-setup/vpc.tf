module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.19.0"

  name = "qa"
  cidr = "10.0.0.0/16"

  azs             = ["${var.region}a"]
  private_subnets = ["10.0.1.0/24"]
  public_subnets  = ["10.0.101.0/24"]

  # AI note: Single NAT gateway in the public subnet — catches egress for things we
  # don't have VPC endpoints for (Docker Hub, github, etc.). VPC interface
  # and gateway endpoints take precedence over the 0.0.0.0/0 NAT route, so
  # SSM/ECR/S3 traffic still stays on the private backbone.
  # Human note: Unfortunately, NAT Gateway won the war, but use endpoints where possible.
  enable_nat_gateway = true
  single_nat_gateway = true

  enable_dns_support   = true
  enable_dns_hostnames = true
}

resource "aws_security_group" "qa_ec2" {
  name        = "qa-ec2"
  description = "QA ephemeral EC2 - egress only"
  vpc_id      = module.vpc.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "qa-ec2" }

  lifecycle {
    prevent_destroy = false
  }
}

# VPC endpoints — SSM, ECR, S3 (no NAT needed)

resource "aws_security_group" "vpc_endpoints" {
  name        = "qa-vpc-endpoints"
  description = "Allow HTTPS from VPC for endpoints"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }

  tags = { Name = "qa-vpc-endpoints" }
}

# SSM requires three endpoints
resource "aws_vpc_endpoint" "ssm" {
  for_each = toset(["ssm", "ssmmessages", "ec2messages"])

  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
}

# ECR requires two interface endpoints + S3 gateway
resource "aws_vpc_endpoint" "ecr" {
  for_each = toset(["ecr.api", "ecr.dkr"])

  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids
}

# STS — needed by `aws sts get-caller-identity` in pull_images.sh and by any
# other AWS SDK call that implicitly resolves credentials against STS.
resource "aws_vpc_endpoint" "sts" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.region}.sts"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
}
