# =============================================================================
# variables.tf — input variables for the dev environment
# =============================================================================

variable "project_id" {
  description = "GCP project ID. Created by scripts/bootstrap-gcp.sh."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "Project ID must be 6-30 characters, lowercase alphanumeric and hyphens, start with a letter."
  }
}

variable "region" {
  description = "Default GCP region for regional resources."
  type        = string
  default     = "europe-west2"
}

variable "bq_location" {
  description = "Location of the BigQuery datasets and the data bucket. Must be US: the warehouse joins the public gnomAD v3 table (bigquery-public-data.gnomAD), which is in US."
  type        = string
  default     = "US"

  validation {
    condition     = var.bq_location == "US"
    error_message = "bq_location must be US, where the public gnomAD dataset lives; BigQuery cannot join across locations."
  }
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "billing_account_id" {
  description = "GCP billing account ID. Used for the budget alert."
  type        = string
}

variable "monthly_budget_amount" {
  description = "Monthly budget cap in GBP. Triggers alerts at 50%, 90%, 100%."
  type        = number
  default     = 30
}
