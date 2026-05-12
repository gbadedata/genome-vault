# =============================================================================
# outputs.tf
# =============================================================================

output "project_id" {
  description = "The GCP project ID."
  value       = var.project_id
}

output "project_number" {
  description = "The GCP project number (numeric)."
  value       = data.google_project.current.number
}

output "region" {
  description = "Default region for regional resources."
  value       = var.region
}

output "bq_location" {
  description = "BigQuery location."
  value       = var.bq_location
}

output "environment" {
  description = "Deployment environment."
  value       = var.environment
}

output "budget_id" {
  description = "ID of the monthly budget alert."
  value       = google_billing_budget.monthly_cap.id
}
