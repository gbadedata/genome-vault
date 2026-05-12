# =============================================================================
# providers.tf — GCP provider configuration
# =============================================================================

provider "google" {
  project = var.project_id
  region  = var.region

  # Force user_project_override so the GCP Billing Budgets API (and any
  # other "user project" APIs) bill quota against genome-vault-202605
  # rather than the gcloud CLI's own internal client project.
  user_project_override = true
  billing_project       = var.project_id

  default_labels = {
    project     = "genome-vault"
    environment = var.environment
    managed_by  = "terraform"
    owner       = "gbadedata"
  }
}

provider "google-beta" {
  project = var.project_id
  region  = var.region

  user_project_override = true
  billing_project       = var.project_id

  default_labels = {
    project     = "genome-vault"
    environment = var.environment
    managed_by  = "terraform"
    owner       = "gbadedata"
  }
}
