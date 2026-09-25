#!/usr/bin/env bash
# 07-build-node-cache.sh — PHASE 3. Build the GKE Secondary Boot Disk image.
#
# What it does: builds a GCE disk image containing the vLLM container layers
# already extracted into containerd's image store. GPU nodes then boot with
# that disk attached and skip the image pull entirely.
#
# Our measured baseline (run 1, 2026-09-25): cold start 709s, of which the
# 8.73 GB image pull was 373s (53%). This is the optimization that targets it.
#
# Prerequisites:
#   - Go >= 1.21                (brew install go)
#   - ./07a-mirror-vllm.sh already run (image must be in Artifact Registry;
#     the builder VM uses a GCP SA token and cannot reach Docker Hub)
#   - containerfilesystem.googleapis.com enabled (already is)
#
# Takes 30-45 min. Costs: one temporary builder VM + 50GB disk image
# (~$0.10/month) + a GCS bucket for logs.
set -euo pipefail
cd "$(dirname "$0")" && source ./00-config.sh

DISK_NAME="vllm-node-cache-$(date +%Y%m%d)"
DISK_SIZE_GB=50
LOG_BUCKET="gs://${PROJECT}-poc-node-cache-logs"

echo "=========================================================="
echo " PHASE 3 — Secondary Boot Disk"
echo "   disk image: $DISK_NAME  (${DISK_SIZE_GB}GB, $ZONE)"
echo "   source:     $VLLM_IMAGE_AR"
echo "   duration:   30-45 min"
echo "=========================================================="

if ! gcloud artifacts docker images describe "$VLLM_IMAGE_AR" --project="$PROJECT" &>/dev/null; then
  echo
  echo "STOP: $VLLM_IMAGE_AR is not in Artifact Registry."
  echo "      Run ./07a-mirror-vllm.sh first."
  exit 1
fi
echo "  source image present in AR."

export PATH="$HOME/go/bin:/opt/homebrew/bin:/usr/local/go/bin:$PATH"
if ! command -v go &>/dev/null; then
  echo "ERROR: Go not found. Install with:  brew install go"
  exit 1
fi
echo "  Go $(go version | awk '{print $3}')"

echo
echo "=== 1/3  GCS log bucket ==="
gcloud storage buckets create "$LOG_BUCKET" --project="$PROJECT" --location="$REGION" 2>/dev/null \
  || echo "    exists, reusing."

echo
echo "=== 2/3  Fetch and PATCH gke-disk-image-builder ==="
# UPSTREAM BUG (hit on 2026-09-25):
#   imager.go hardcodes SourceImage = debian-11-bullseye-v20230912 for the
#   builder VM. Debian 11 is now archived; its startup script runs
#   `apt install containerd`, apt resolves a version whose .deb has been
#   rotated out of the security pool, and the fetch 404s. containerd never
#   installs, `ctr` is missing, and the build dies in ~20 seconds with only
#   "startup-script-url exit status 1" in the Daisy output. The real error is
#   only visible in the VM serial-port log in the GCS bucket.
# FIX: point the builder VM at a current Debian 12 image. Nothing else changes.
BUILDER_IMAGE="${BUILDER_IMAGE:-debian-12-bookworm-v20260921}"
TOOLS_DIR="$(pwd)/tools-dib"

if [ ! -d "$TOOLS_DIR/.git" ]; then
  rm -rf "$TOOLS_DIR"
  git clone --quiet --filter=blob:none --sparse https://github.com/ai-on-gke/tools.git "$TOOLS_DIR"
  git -C "$TOOLS_DIR" sparse-checkout set gke-disk-image-builder
fi

cd "$TOOLS_DIR/gke-disk-image-builder"
BEFORE=$(grep -c "debian-11-bullseye-v20230912" imager.go || true)
sed -i.orig "s|projects/debian-cloud/global/images/debian-11-bullseye-v20230912|projects/debian-cloud/global/images/${BUILDER_IMAGE}|g" imager.go
AFTER=$(grep -c "$BUILDER_IMAGE" imager.go || true)
echo "    patched builder base image: debian-11-bullseye-v20230912 -> $BUILDER_IMAGE"
echo "    occurrences replaced: $BEFORE -> $AFTER"
go mod tidy

echo
echo "=== 3/3  Build disk image (30-45 min) ==="
go run ./cli \
  --project-name="$PROJECT" \
  --image-name="$DISK_NAME" \
  --zone="$ZONE" \
  --gcs-path="$LOG_BUCKET" \
  --disk-size-gb="$DISK_SIZE_GB" \
  --container-image="$VLLM_IMAGE_AR" \
  --timeout=45m \
  --image-pull-auth=ServiceAccountToken

cd - >/dev/null

cat <<EOF

==========================================================
 Disk image built: $DISK_NAME
==========================================================

The GPU node pool must be RECREATED — a secondary boot disk cannot be
attached to an existing pool.

  1. Edit 00-config.sh:
       export VLLM_DISK_IMAGE="$DISK_NAME"
       export VLLM_IMAGE_SOURCE="ar"

  2. Delete the current GPU pool:
       gcloud container node-pools delete gpu-pool \\
         --cluster $CLUSTER --zone $ZONE --project $PROJECT --quiet

  3. Recreate it (03 skips the existing cluster, rebuilds gpu-pool):
       ./03-create-cluster.sh

  4. Repoint vLLM at the AR image and confirm everything is back at zero:
       kubectl set image deployment/vllm vllm=$VLLM_IMAGE_AR -n $NAMESPACE

  5. Run ./05-smoke-test.sh again and compare.

 RUN 1 BASELINE (measured): cold start 709s
   node provision       ~110s
   image pull (8.73GB)   373s   <-- this is what should collapse to ~30s
   vLLM boot + load      213s
 RUN 2 TARGET: roughly 350s

NOTE: --enable-image-streaming is required to unlock the secondary boot disk
plugin even though image streaming itself is harmful for this workload. 03
adds that flag automatically whenever VLLM_DISK_IMAGE is set.

NOTE: any vLLM version bump means rebuilding this disk image and recreating
the node pool. That standing maintenance cost belongs in the write-up.
EOF
