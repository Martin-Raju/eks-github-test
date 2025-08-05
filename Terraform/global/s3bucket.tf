resource "aws_s3_bucket" "poc" {
  bucket        = "poc-tfstate-bucket-0123456"
  force_destroy = true

  tags = {
    Name        = "poc-tfstate-bucket-0123456"
    Environment = "live"
  }
}

resource "aws_s3_bucket_versioning" "poc" {
  bucket = aws_s3_bucket.poc.id

  versioning_configuration {
    status = "Enabled"
  }
}
