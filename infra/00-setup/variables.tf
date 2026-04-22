variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "qa_bucket_name" {
  description = "S3 bucket for QA artifacts"
  type        = string
  default     = "godot-eks-qa-2025"
}

variable "qa_ami_id" {
  description = "AMI for QA EC2 instances. Must have the SSM agent pre-baked (stock Amazon Linux is fine). Docker + the compose plugin are installed at boot by the user-data bootstrap in qa_ec2.py."
  type        = string
  default     = "ami-098e39bafa7e7303d" # stock Amazon Linux x86 (SSM agent included)
}

variable "services" {
  description = "List of service names for ECR repositories"
  type        = list(string)
  default     = ["shooter", "auth-service", "score-service", "session-service"]
}
