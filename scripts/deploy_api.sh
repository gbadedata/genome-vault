#!/usr/bin/env bash
# =============================================================================
# scripts/deploy_api.sh — build the API image and deploy it to Cloud Run
# =============================================================================
# 1. terraform apply: Artifact Registry repo, read-only service account and
#    its two permissions (and the current service, if one is deployed).
# 2. Cloud Build builds deploy/api/Dockerfile and pushes it, tagged with the
#    git commit.
# 3. terraform apply with the new image (written to api_image.auto.tfvars,
#    so a later plain `terraform apply` keeps it).
# 4. scripts/api_smoke.py calls every endpoint on the live URL and writes
#    data/work/evidence/api_smoke.json.
#
# Usage: bash scripts/deploy_api.sh      (Terraform asks before each apply)
# =============================================================================
set -euo pipefail

PROJECT="${GV_PROJECT_ID:-genome-vault-202605}"
REGION="${GV_REGION:-europe-west2}"
TF_DIR="infra/terraform/environments/dev"

step() { printf '\n== %s\n' "$1"; }
fail() { printf '\nSTOP: %s\n' "$1" >&2; exit 1; }

cd "$(dirname "$0")/.."

# Refuse to run stale code (see load_bigquery.sh). GV_ALLOW_STALE=1 skips it.
if git rev-parse --git-dir >/dev/null 2>&1; then
  CODE_VERSION="$(git rev-parse --short HEAD)$(git diff --quiet HEAD -- src deploy || echo '+local-changes')"
  if [[ "${GV_ALLOW_STALE:-0}" != "1" ]] && git fetch -q origin main 2>/dev/null; then
    behind=$(git rev-list --count HEAD..origin/main)
    [[ "$behind" == "0" ]] || fail "this copy is $behind commit(s) behind GitHub: run git pull first"
  fi
else
  CODE_VERSION="unknown"
fi
echo "== Code version $CODE_VERSION, project $PROJECT, region $REGION"
for tool in gcloud terraform python; do command -v "$tool" >/dev/null || fail "$tool is not on PATH"; done

TAG="${CODE_VERSION//+/-}"
IMAGE="$REGION-docker.pkg.dev/$PROJECT/genome-vault/api:$TAG"

# -----------------------------------------------------------------------------
step "1/4 Registry, service account and permissions (Terraform)"
terraform -chdir="$TF_DIR" init -input=false >/dev/null
terraform -chdir="$TF_DIR" apply

# -----------------------------------------------------------------------------
step "2/4 Building $IMAGE with Cloud Build"
CTX="$(mktemp -d)"
trap 'rm -rf "$CTX"' EXIT
mkdir -p "$CTX/deploy/api" "$CTX/src/genome_vault"
cp deploy/api/Dockerfile "$CTX/Dockerfile"
cp deploy/api/requirements.txt "$CTX/deploy/api/"
cp src/genome_vault/__init__.py "$CTX/src/genome_vault/"
cp -r src/genome_vault/api "$CTX/src/genome_vault/"
find "$CTX" -name __pycache__ -prune -exec rm -rf {} +
gcloud builds submit "$CTX" --tag "$IMAGE" --project "$PROJECT"

# -----------------------------------------------------------------------------
step "3/4 Deploying to Cloud Run (Terraform)"
cat > "$TF_DIR/api_image.auto.tfvars" <<TFVARS
# Written by scripts/deploy_api.sh; keeps the deployed image on later applies.
api_image        = "$IMAGE"
api_code_version = "$CODE_VERSION"
TFVARS
terraform -chdir="$TF_DIR" apply

# -----------------------------------------------------------------------------
step "4/4 Smoke test"
URL="$(terraform -chdir="$TF_DIR" output -raw api_url)"
python scripts/api_smoke.py "$URL" --expect-version "$CODE_VERSION" --out data/work/evidence/api_smoke.json
step "Done. API: $URL  (docs: $URL/docs)"
