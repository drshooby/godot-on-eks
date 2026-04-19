# -----------------------------------------------------------------------------
# EC2 role — SSM + ECR pull + S3 read (for QA setup scripts)
# -----------------------------------------------------------------------------

resource "aws_iam_role" "qa_ec2" {
  name = "qa-ec2"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "qa_ec2_ssm" {
  role       = aws_iam_role.qa_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "qa_ec2_ecr" {
  role       = aws_iam_role.qa_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

resource "aws_iam_role_policy" "qa_ec2_s3" {
  name = "qa-s3-read"
  role = aws_iam_role.qa_ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:GetObject", "s3:ListBucket"]
      Resource = [
        aws_s3_bucket.qa.arn,
        "${aws_s3_bucket.qa.arn}/*",
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "qa_ec2" {
  name = "qa-ec2"
  role = aws_iam_role.qa_ec2.name
}

# -----------------------------------------------------------------------------
# Lambda role — manage ephemeral EC2 + SSM commands
# -----------------------------------------------------------------------------

resource "aws_iam_role" "qa_lambda" {
  name = "qa-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "qa_lambda_logs" {
  role       = aws_iam_role.qa_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "qa_lambda" {
  name = "qa-lambda"
  role = aws_iam_role.qa_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:RunInstances",
          "ec2:TerminateInstances",
          "ec2:DescribeInstances",
          "ec2:CreateTags",
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.qa_ec2.arn
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:DescribeInstanceInformation",
          "ssm:SendCommand",
          "ssm:ListCommandInvocations",
          "ssm:GetCommandInvocation",
        ]
        Resource = "*"
      },
    ]
  })
}
