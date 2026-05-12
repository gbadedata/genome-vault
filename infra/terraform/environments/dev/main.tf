# =============================================================================
# main.tf — dev environment composition
# =============================================================================
# Phase 1 deliberately keeps this minimal:
#   - A budget alert that emails when spend hits 50%, 90%, 100% of the monthly cap.
#   - Project-level labels.
#
# BigQuery datasets, GCS data buckets, and IAM bindings are added in Phase 2.

# Project metadata is set on the provider's default_labels.
# Surface the configured project ID for visibility in plan/apply output.

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
