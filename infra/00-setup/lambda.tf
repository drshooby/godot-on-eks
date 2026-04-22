data "archive_file" "qa_lambda" {
  type        = "zip"
  source_file = "${path.module}/../01-run-qa/lambda/qa_ec2.py"
  output_path = "${path.module}/qa_ec2.zip"
}

# Destination for full SSM Run Command output — SSM's inline response is capped
# at 24KB, which silently truncates verbose docker compose output. Streaming
# to CloudWatch gives us the full log regardless of size.
resource "aws_cloudwatch_log_group" "qa_ssm" {
  name              = "/aws/ssm/qa-runner"
  retention_in_days = 14
}

resource "aws_lambda_function" "qa_runner" {
  function_name    = "qa-runner"
  role             = aws_iam_role.qa_lambda.arn
  handler          = "qa_ec2.handler"
  runtime          = "python3.12"
  timeout          = 900
  filename         = data.archive_file.qa_lambda.output_path
  source_code_hash = data.archive_file.qa_lambda.output_base64sha256

  environment {
    variables = {
      SUBNET_ID        = module.vpc.private_subnets[0]
      SG_ID            = aws_security_group.qa_ec2.id
      AMI_ID           = var.qa_ami_id
      INSTANCE_PROFILE = aws_iam_instance_profile.qa_ec2.name
      QA_BUCKET        = var.qa_bucket_name
      SSM_LOG_GROUP    = aws_cloudwatch_log_group.qa_ssm.name
    }
  }

  lifecycle {
    prevent_destroy = false
  }
}
