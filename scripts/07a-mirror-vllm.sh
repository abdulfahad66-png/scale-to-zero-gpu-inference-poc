#!/usr/bin/env bash
# 07a-mirror-vllm.sh — copy vllm/vllm-openai:latest from Docker Hub into
# Artifact Registry, using Cloud Build so the 8.7 GB never touches this laptop.
#
# WHY THIS IS NEEDED: the gke-disk-image-builder boots a VM that authenticates
# with a GCP service-account token. It cannot pull from Docker Hub. The image
# has to be in Artifact Registry first.
#
# WHY CLOUD BUILD instead of local docker: pulling 8.7 GB down and pushing
# 8.7 GB back up over home internet is 30-60 min. Cloud Build does the same
# copy inside Google's network in ~4-6 min and costs a few cents.
set -euo pipefail
cd "$(dirname "$0")" && source ./00-config.sh

echo "=========================================================="
echo " Mirror $VLLM_IMAGE_DOCKERHUB  ->  $VLLM_IMAGE_AR"
echo " via Cloud Build (runs in GCP, not on this Mac)"
echo "=========================================================="

if gcloud artifacts docker images describe "$VLLM_IMAGE_AR" --project="$PROJECT" &>/dev/null; then
  echo "Already mirrored. Skipping."
  exit 0
fi

gcloud services enable cloudbuild.googleapis.com --project "$PROJECT" --quiet

CB=$(mktemp /tmp/vllm-cloudbuild-XXXX.yaml)
cat > "$CB" <<'CBEOF'
steps:
  - name: 'gcr.io/cloud-builders/docker'
    args: ['pull', 'vllm/vllm-openai:latest']
  - name: 'gcr.io/cloud-builders/docker'
    args: ['tag', 'vllm/vllm-openai:latest', '${_TARGET}']
  - name: 'gcr.io/cloud-builders/docker'
    args: ['push', '${_TARGET}']
timeout: '2400s'
options:
  machineType: 'E2_HIGHCPU_8'
  diskSizeGb: 100
substitutions:
  _TARGET: ''
CBEOF

echo "Submitting Cloud Build job (4-6 min)..."
gcloud builds submit --no-source \
  --config="$CB" \
  --substitutions="_TARGET=${VLLM_IMAGE_AR}" \
  --project "$PROJECT" --quiet

rm -f "$CB"
echo
echo "Mirrored. Verify:"
gcloud artifacts docker images describe "$VLLM_IMAGE_AR" --project="$PROJECT" \
  --format="value(image_summary.digest)" 2>/dev/null
echo
echo "Now set in 00-config.sh:  export VLLM_IMAGE_SOURCE=\"ar\""
echo "Then:  ./07-build-node-cache.sh"
