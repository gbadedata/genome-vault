# =============================================================================
# api.tf — read-only API on Cloud Run
# =============================================================================
# scripts/deploy_api.sh builds the image with Cloud Build and writes
# api_image.auto.tfvars; with api_image empty, only the registry, service
# account and permissions exist (no service).
#
# The service account can read the gv dataset and run query jobs, nothing else:
# no access to gv_raw, the bucket or any other dataset.

variable "api_image" {
  description = "Container image for the API. Empty: create everything except the Cloud Run service."
  type        = string
  default     = ""
}

variable "api_code_version" {
  description = "git commit the image was built from, reported by /health."
  type        = string
  default     = "unknown"
}

variable "api_public" {
  description = "Allow unauthenticated requests. The app caps bytes per query, bytes per day and requests per IP."
  type        = bool
  default     = true
}

resource "google_project_service" "api" {
  for_each           = toset(["run.googleapis.com", "artifactregistry.googleapis.com", "cloudbuild.googleapis.com"])
  service            = each.value
  disable_on_destroy = false
}

resource "google_artifact_registry_repository" "images" {
  location      = var.region
  repository_id = "genome-vault"
  description   = "genome-vault container images"
  format        = "DOCKER"

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 5
    }
  }
  cleanup_policies {
    id     = "delete-old"
    action = "DELETE"
    condition {
      older_than = "2592000s" # 30 days, unless among the 5 most recent
    }
  }

  depends_on = [google_project_service.api]
}

resource "google_service_account" "api" {
  account_id   = "gv-api"
  display_name = "genome-vault API (read-only)"
}

resource "google_bigquery_dataset_iam_member" "api_reads_warehouse" {
  dataset_id = google_bigquery_dataset.warehouse.dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.api.email}"
}

resource "google_project_iam_member" "api_runs_queries" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.api.email}"
}

resource "google_cloud_run_v2_service" "api" {
  count    = var.api_image == "" ? 0 : 1
  name     = "genome-vault-api"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    service_account                  = google_service_account.api.email
    timeout                          = "30s"
    max_instance_request_concurrency = 20

    scaling {
      min_instance_count = 0 # scale to zero when idle
      max_instance_count = 1 # one process holds the rate limiter and daily budget
    }

    containers {
      image = var.api_image

      ports {
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle = true
      }

      env {
        name  = "GV_API_BACKEND"
        value = "bigquery"
      }
      env {
        name  = "GV_PROJECT_ID"
        value = var.project_id
      }
      env {
        name  = "GV_DATASET"
        value = google_bigquery_dataset.warehouse.dataset_id
      }
      env {
        name  = "GV_CODE_VERSION"
        value = var.api_code_version
      }

      startup_probe {
        http_get {
          path = "/health"
        }
      }
    }
  }

  depends_on = [
    google_project_service.api,
    google_bigquery_dataset_iam_member.api_reads_warehouse,
    google_project_iam_member.api_runs_queries,
  ]
}

resource "google_cloud_run_v2_service_iam_member" "public" {
  count    = var.api_image != "" && var.api_public ? 1 : 0
  name     = google_cloud_run_v2_service.api[0].name
  location = google_cloud_run_v2_service.api[0].location
  role     = "roles/run.invoker"
  member   = "allUsers"
}

output "api_url" {
  description = "URL of the API, once deployed."
  value       = var.api_image == "" ? null : google_cloud_run_v2_service.api[0].uri
}

output "api_image_repository" {
  description = "Where scripts/deploy_api.sh pushes images."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
}
