#!/usr/bin/env bash
# 02-build-images.sh — build gateway + worker as linux/amd64, push to Artifact Registry.
#
# THE ONE THING THAT MATTERS: your Mac is arm64, GKE nodes are amd64. A plain
# `docker build` here produces an arm64 image and the pod crash-loops with
# "exec format error" — which does not mention architecture anywhere.
# --platform linux/amd64 is mandatory.
#
# Cost: Artifact Registry storage only, ~$0.02/month for our two images.
set -euo pipefail
cd "$(dirname "$0")" && source ./00-config.sh

[ -d "$REPO_DIR/gateway" ] || { echo "ERROR: repo missing. Run ./10-fetch-repo.sh"; exit 1; }

echo "=== 1/4  Artifact Registry repo ==="
if gcloud artifacts repositories describe "$AR_REPO" --location=us --project="$PROJECT" &>/dev/null; then
  echo "    exists, reusing: $AR_REPO"
else
  gcloud artifacts repositories create "$AR_REPO" \
    --repository-format=docker --location=us --project="$PROJECT" \
    --labels="$GCP_LABELS" \
    --description="AI learning POC - scale-to-zero GPU inference"
fi

echo
echo "=== 2/4  Docker auth to Artifact Registry ==="
gcloud auth print-access-token \
  | docker login -u oauth2accesstoken --password-stdin us-docker.pkg.dev

echo
echo "=== 3/4  Build + push gateway and worker (linux/amd64) ==="
docker buildx create --name poc-builder --use 2>/dev/null || docker buildx use poc-builder
for COMPONENT in gateway worker; do
  echo
  echo "--- $COMPONENT ---"
  docker buildx build \
    --platform linux/amd64 \
    --tag "${REGISTRY}/${COMPONENT}:latest" \
    --push \
    "$REPO_DIR/$COMPONENT"
done

echo
echo "=== 4/4  vLLM image ==="
if [ "$VLLM_IMAGE_SOURCE" = "ar" ]; then
  echo "    Mirroring $VLLM_IMAGE_DOCKERHUB into Artifact Registry."
  echo "    WARNING: pulls ~8GB to this Mac and pushes ~8GB back up."
  echo "    Only needed before building the secondary boot disk (phase 3)."
  read -rp "    Continue? (y/N): " YN
  [[ "$YN" =~ ^[Yy]$ ]] || { echo "    Skipped."; exit 0; }
  docker pull --platform linux/amd64 "$VLLM_IMAGE_DOCKERHUB"
  docker tag "$VLLM_IMAGE_DOCKERHUB" "$VLLM_IMAGE_AR"
  docker push "$VLLM_IMAGE_AR"
else
  echo "    VLLM_IMAGE_SOURCE=dockerhub — GKE pulls $VLLM_IMAGE_DOCKERHUB directly."
  echo "    Nothing goes through this laptop. Correct for run 1."
fi

echo
echo "Images ready:"
echo "  ${REGISTRY}/gateway:latest"
echo "  ${REGISTRY}/worker:latest"
echo
echo "Next:  ./03-create-cluster.sh    <-- this one starts billing"
