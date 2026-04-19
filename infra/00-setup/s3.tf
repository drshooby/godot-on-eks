resource "aws_s3_bucket" "qa" {
  bucket        = var.qa_bucket_name
  force_destroy = true
  lifecycle {
    prevent_destroy = false
  }
}

resource "aws_s3_bucket_versioning" "qa" {
  bucket = aws_s3_bucket.qa.id
  versioning_configuration {
    status = "Enabled"
  }
  lifecycle {
    prevent_destroy = false
  }
}
