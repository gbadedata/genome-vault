# =============================================================================
# backend.tf — Terraform state stored in GCS
# =============================================================================
# The bucket is created by scripts/bootstrap-gcp.sh before terraform init runs.

terraform {
  backend "gcs" {
    bucket = "genome-vault-202605-tfstate"
    prefix = "environments/dev"
  }
}
