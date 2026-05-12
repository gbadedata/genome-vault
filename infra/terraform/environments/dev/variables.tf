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
  description = "BigQuery location. Use 'EU' or 'US' for multi-region, or a specific region like 'europe-west2'."
  type        = string
  default     = "EU"
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
