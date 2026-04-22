# UAT — see docs/uat-plan.md
# ettukube.com is registered in Cloudflare; you add NS delegation for the Route 53 child zone (e.g. shmup.ettukube.com).
# UAT: aws_route53_record for uat_fqdn → Gateway/LB. This is also the hostname in Helm / cert-manager / HTTPRoute.

variable "aws_region" {
  description = "AWS region for UAT"
  type        = string
  default     = "us-east-1"
}

variable "uat_fqdn" {
  description = "FQDN for UAT (Route 53 record name, cert-manager, HTTPRoute hosts). Must be a hostname under route53_child_zone_name."
  type        = string
  default     = "uat.shmup.ettukube.com"
}

variable "route53_child_zone_name" {
  description = "Public Route 53 hosted zone name (delegate this label from Cloudflare to the zone name_servers output)."
  type        = string
  default     = "shmup.ettukube.com"
}

variable "uat_cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "godot-uat"
}

variable "cluster_version" {
  description = "Kubernetes version for the UAT control plane"
  type        = string
  default     = "1.31"
}

variable "vpc_name" {
  type        = string
  default     = "godot-uat-vpc"
  description = "VPC name tag (dedicated UAT network; separate CIDR from infra/00-setup QA)."
}

variable "vpc_cidr" {
  type        = string
  default     = "10.20.0.0/16"
  description = "Dedicated UAT VPC CIDR (does not overlap default 00-setup QA 10.0.0.0/16)."
}

variable "aws_azs" {
  description = "Availability zones for the UAT VPC"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  type        = list(string)
  default     = ["10.20.1.0/24", "10.20.2.0/24"]
  description = "Public subnets (NAT, load balancers)."
}

variable "private_subnet_cidrs" {
  type        = list(string)
  default     = ["10.20.101.0/24", "10.20.102.0/24"]
  description = "Private subnets (EKS nodes, RDS)."
}

variable "tags" {
  type = map(string)
  default = {
    Environment = "uat"
    ManagedBy   = "terraform"
    Project     = "godot-on-eks"
  }
}

variable "uat_gateway_lb_dns_name" {
  description = "After installing Envoy Gateway (or your Gateway API controller), set this to the public load balancer DNS name for the UAT alias record. Leave empty on first apply; update and re-apply once the LB exists."
  type        = string
  default     = ""
}

variable "uat_gateway_lb_hosted_zone_id" {
  description = "Route 53 canonical hosted zone ID for the load balancer (depends on LB type). Required when uat_gateway_lb_dns_name is set."
  type        = string
  default     = ""
}

variable "acme_email" {
  description = "Email for Let's Encrypt / cert-manager ACME registration (passed to Helm values)."
  type        = string
  default     = "ops@example.com"
}

variable "db_instance_class" {
  description = "RDS MySQL instance class (matches JVM stack in LOCAL-DOCKER.md)."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage" {
  type    = number
  default = 20
}
