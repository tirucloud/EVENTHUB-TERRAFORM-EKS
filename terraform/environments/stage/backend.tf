# State for the stage environment.
#
# Left as local state so `terraform init` works with nothing set up first. The
# state file lands in this directory as terraform.tfstate and is gitignored.
#
# Local state is fine for one person on one machine. The moment a second person
# applies, or you want history and locking, switch to S3 — uncomment the block
# below and run:
#
#     aws s3api create-bucket \
#       --bucket eventhub-tfstate-<account-id> \
#       --region us-east-1
#     aws s3api put-bucket-versioning \
#       --bucket eventhub-tfstate-<account-id> \
#       --versioning-configuration Status=Enabled
#
#     terraform init -migrate-state
#
# Each environment keeps its own key, so the three never touch each other's
# state.
#
# No DynamoDB table is needed. Since Terraform 1.11, `use_lockfile = true` holds
# the lock as an object beside the state file; any guide telling you to create a
# lock table predates that.

terraform {
  backend "s3" {
    bucket       = "eventhub-tfstate-015906850208"
    key          = "stage/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
