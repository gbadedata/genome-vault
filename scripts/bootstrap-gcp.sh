#!/usr/bin/env bash
# =============================================================================
# scripts/bootstrap-gcp.sh
# =============================================================================
# One-time bootstrap for genome-vault on GCP.
#
# What it does:
#   1. Creates the GCP project if it doesn't exist
#   2. Attaches it to your billing account
#   3. Enables required GCP APIs
#   4. Creates the GCS bucket that will hold Terraform state
#   5. Configures gcloud and bq to default to this project
#
# What it does NOT do:
#   - Provision any BigQuery datasets (that's Terraform's job)
#   - Provision any GCS data buckets (that's Terraform's job)
#   - Deploy any application code
#
# Idempotent — safe to re-run.
# =============================================================================

set -euo pipefail

# Color codes
if [[ -t 1 ]]; then
  GREEN='\033[0;32m'
  BLUE='\033[0;34m'
  YELLOW='\033[0;33m'
  RED='\033[0;31m'
  RESET='\033[0m'
else
  GREEN=''; BLUE=''; YELLOW=''; RED=''; RESET=''
fi

ok()      { printf "${GREEN}✓${RESET}  %s\n" "$1"; }
info()    { printf "${BLUE}ℹ${RESET}  %s\n" "$1"; }
warn()    { printf "${YELLOW}⚠${RESET}  %s\n" "$1"; }
fatal()   { printf "${RED}✗${RESET}  %s\n" "$1" >&2; exit 1; }
heading() { printf "\n${BLUE}=== %s ===${RESET}\n" "$1"; }

# -----------------------------------------------------------------------------
# Configuration — edit these if you fork the project
# -----------------------------------------------------------------------------
PROJECT_ID="genome-vault-202605"
PROJECT_NAME="genome-vault"
BILLING_ACCOUNT_ID="018548-DE72C7-6EAF1D"
REGION="europe-west2"
BQ_LOCATION="EU"
TFSTATE_BUCKET="${PROJECT_ID}-tfstate"

# APIs required for the platform
REQUIRED_APIS=(
  "bigquery.googleapis.com"
  "storage.googleapis.com"
  "dataflow.googleapis.com"
  "compute.googleapis.com"
  "iam.googleapis.com"
  "cloudbilling.googleapis.com"
  "billingbudgets.googleapis.com"
  "cloudresourcemanager.googleapis.com"
  "logging.googleapis.com"
  "monitoring.googleapis.com"
  "run.googleapis.com"
  "artifactregistry.googleapis.com"
  "serviceusage.googleapis.com"
)

# -----------------------------------------------------------------------------
# Pre-flight checks
# -----------------------------------------------------------------------------
heading "Pre-flight checks"

command -v gcloud >/dev/null 2>&1 || fatal "gcloud not found on PATH"
command -v gsutil >/dev/null 2>&1 || fatal "gsutil not found on PATH"
ok "gcloud and gsutil are on PATH"

# Verify auth
if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q "@"; then
  fatal "No active gcloud account. Run: gcloud auth login"
fi
ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)")
ok "Authenticated as $ACTIVE_ACCOUNT"

# Verify billing account exists and is open
if ! gcloud billing accounts describe "$BILLING_ACCOUNT_ID" --format="value(open)" 2>/dev/null | grep -q "True"; then
  fatal "Billing account $BILLING_ACCOUNT_ID not found or not open. Check: gcloud billing accounts list"
fi
ok "Billing account $BILLING_ACCOUNT_ID is open"

# -----------------------------------------------------------------------------
# Step 1 — Create the project
# -----------------------------------------------------------------------------
heading "Step 1 — Project"

if gcloud projects describe "$PROJECT_ID" >/dev/null 2>&1; then
  STATE=$(gcloud projects describe "$PROJECT_ID" --format="value(lifecycleState)")
  if [[ "$STATE" != "ACTIVE" ]]; then
    fatal "Project $PROJECT_ID exists but state is $STATE. Either undelete or pick a new ID."
  fi
  ok "Project $PROJECT_ID already exists and is ACTIVE"
else
  info "Creating project $PROJECT_ID..."
  gcloud projects create "$PROJECT_ID" --name="$PROJECT_NAME"
  ok "Created project $PROJECT_ID"
fi

# -----------------------------------------------------------------------------
# Step 2 — Attach billing
# -----------------------------------------------------------------------------
heading "Step 2 — Billing"

CURRENT_BILLING=$(gcloud billing projects describe "$PROJECT_ID" --format="value(billingAccountName)" 2>/dev/null || echo "")
EXPECTED_BILLING="billingAccounts/$BILLING_ACCOUNT_ID"

if [[ "$CURRENT_BILLING" == "$EXPECTED_BILLING" ]]; then
  ok "Billing already linked to $BILLING_ACCOUNT_ID"
else
  info "Linking billing account..."
  gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT_ID"
  ok "Billing linked to $BILLING_ACCOUNT_ID"
fi

# -----------------------------------------------------------------------------
# Step 3 — Enable APIs
# -----------------------------------------------------------------------------
heading "Step 3 — APIs"

info "Enabling ${#REQUIRED_APIS[@]} APIs (this may take 1-2 minutes)..."
gcloud services enable "${REQUIRED_APIS[@]}" --project="$PROJECT_ID"
ok "All required APIs enabled"

# -----------------------------------------------------------------------------
# Step 4 — Create Terraform state bucket
# -----------------------------------------------------------------------------
heading "Step 4 — Terraform state bucket"

if gsutil ls -b "gs://${TFSTATE_BUCKET}" >/dev/null 2>&1; then
  ok "Bucket gs://${TFSTATE_BUCKET} already exists"
else
  info "Creating bucket gs://${TFSTATE_BUCKET} in ${BQ_LOCATION}..."
  gsutil mb -p "$PROJECT_ID" -l "$BQ_LOCATION" "gs://${TFSTATE_BUCKET}"
  ok "Created bucket gs://${TFSTATE_BUCKET}"
fi

info "Enabling versioning on state bucket..."
gsutil versioning set on "gs://${TFSTATE_BUCKET}"
ok "Versioning enabled (protects against accidental state loss)"

info "Setting uniform bucket-level access (recommended security setting)..."
gsutil uniformbucketlevelaccess set on "gs://${TFSTATE_BUCKET}" 2>/dev/null || \
  warn "Could not set uniform bucket-level access (may already be configured)"

# -----------------------------------------------------------------------------
# Step 5 — Configure gcloud and bq defaults
# -----------------------------------------------------------------------------
heading "Step 5 — gcloud / bq defaults"

gcloud config set project "$PROJECT_ID"
ok "gcloud default project set to $PROJECT_ID"

gcloud auth application-default set-quota-project "$PROJECT_ID" 2>/dev/null
ok "ADC quota project set to $PROJECT_ID"

# Update .bigqueryrc to point at the new project
BQRC="$HOME/.bigqueryrc"
if [[ -f "$BQRC" ]]; then
  if grep -q "^project_id" "$BQRC"; then
    sed -i "s|^project_id.*|project_id = $PROJECT_ID|" "$BQRC"
    ok "Updated project_id in $BQRC"
  else
    info "$BQRC exists but has no project_id setting — leaving it alone"
  fi
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
heading "Bootstrap complete"

cat <<EOF

Resource              Value
--------------------  ----------------------------------------
GCP Project ID        $PROJECT_ID
Billing Account       $BILLING_ACCOUNT_ID
Region                $REGION
BigQuery Location     $BQ_LOCATION
Terraform State       gs://${TFSTATE_BUCKET}

APIs Enabled          ${#REQUIRED_APIS[@]} APIs (bigquery, storage, dataflow, run, ...)

Next steps:

  1. cd infra/terraform/environments/dev
  2. terraform init      # connects to gs://${TFSTATE_BUCKET}
  3. terraform plan      # shows what will be created
  4. terraform apply     # creates BigQuery datasets, GCS buckets, IAM

To tear everything down later:

  terraform destroy

EOF
