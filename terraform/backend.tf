# Update bucket, key, and region to match your own S3 state bucket.
# The bucket must exist before running terraform init.
# See README for setup instructions.
terraform {
  backend "s3" {
    bucket = "your-terraform-state-bucket"
    key    = "terraform/state/foundryvtt-ecs.tfstate"
    region = "ap-southeast-2" # change to your region
  }
}
