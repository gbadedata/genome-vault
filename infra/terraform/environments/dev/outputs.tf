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

output "data_bucket" {
  description = "Bucket for the loader's Parquet output."
  value       = google_storage_bucket.data.name
}

output "raw_dataset" {
  description = "BigQuery dataset for loader tables."
  value       = google_bigquery_dataset.raw.dataset_id
}

output "warehouse_dataset" {
  description = "BigQuery dataset for dbt models."
  value       = google_bigquery_dataset.warehouse.dataset_id
}
