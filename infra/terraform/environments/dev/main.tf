# =============================================================================
# main.tf — dev environment composition
# =============================================================================
#   - A budget alert at 50%, 90% and 100% of the monthly cap.
#   - A GCS bucket for the loader's Parquet output (one prefix per load run).
#   - BigQuery datasets: gv_raw (loader tables) and gv (dbt models).
#
# Everything data-bearing is in var.bq_location (US): the warehouse joins the
# public gnomAD v3 table, which is in US, and BigQuery cannot join datasets
# in different locations. Labels come from the provider's default_labels.

# -----------------------------------------------------------------------------
# Budget alert — protect against runaway costs
# -----------------------------------------------------------------------------
resource "google_billing_budget" "monthly_cap" {
  billing_account = var.billing_account_id
  display_name    = "genome-vault ${var.environment} monthly cap"

  budget_filter {
    projects = ["projects/${data.google_project.current.number}"]
  }

  amount {
    specified_amount {
      currency_code = "GBP"
      units         = tostring(var.monthly_budget_amount)
    }
  }

  threshold_rules {
    threshold_percent = 0.5
    spend_basis       = "CURRENT_SPEND"
  }
  threshold_rules {
    threshold_percent = 0.9
    spend_basis       = "CURRENT_SPEND"
  }
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "CURRENT_SPEND"
  }

}

data "google_project" "current" {
  project_id = var.project_id
}

# -----------------------------------------------------------------------------
# Data bucket — Parquet from `genome-vault load`, under runs/<run_id>/
# -----------------------------------------------------------------------------
resource "google_storage_bucket" "data" {
  name                        = "${var.project_id}-gv-data"
  location                    = var.bq_location
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true # dev: the data can be rebuilt from the public sources

  # Each run's Parquet is loaded into BigQuery straight away; keep 90 days of
  # runs for provenance, then let them go.
  lifecycle_rule {
    condition {
      age            = 90
      matches_prefix = ["runs/"]
    }
    action {
      type = "Delete"
    }
  }
}

# -----------------------------------------------------------------------------
# BigQuery datasets
# -----------------------------------------------------------------------------
resource "google_bigquery_dataset" "raw" {
  dataset_id                 = "gv_raw"
  friendly_name              = "genome-vault raw"
  description                = "Tables written by genome-vault load (1000 Genomes, ClinVar, Ensembl, samples), replaced on each load."
  location                   = var.bq_location
  delete_contents_on_destroy = true
}

resource "google_bigquery_dataset" "warehouse" {
  dataset_id                 = "gv"
  friendly_name              = "genome-vault warehouse"
  description                = "dbt models: staging views, star schema, population-genetics and QC tables."
  location                   = var.bq_location
  delete_contents_on_destroy = true
}
