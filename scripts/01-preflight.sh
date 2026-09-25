#!/usr/bin/env bash
# 01-preflight.sh — READ-ONLY. Creates nothing, changes nothing, costs nothing.
set -uo pipefail
cd "$(dirname "$0")" && source ./00-config.sh

PASS=0; FAIL=0; WARN=0
ok()   { echo "  [ OK ]  $*"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL]  $*"; FAIL=$((FAIL+1)); }
warn() { echo "  [WARN]  $*"; WARN=$((WARN+1)); }

echo
echo "=========================================================="
echo " PREFLIGHT — $PROJECT / $ZONE"
echo "=========================================================="

echo
echo "1. Local tools"
for t in gcloud kubectl helm docker git; do
  if command -v "$t" &>/dev/null; then ok "$t  $(command -v $t)"; else bad "$t not found"; fi
done
if docker buildx version &>/dev/null; then ok "docker buildx available"
else bad "docker buildx missing — needed for amd64 builds on Apple Silicon"; fi
if docker info &>/dev/null; then ok "docker daemon running"
else bad "docker daemon not running — start Docker Desktop"; fi
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
  warn "host is arm64. Images MUST be built --platform linux/amd64 (02 does this)."
else ok "host arch $ARCH"; fi

echo
echo "2. GCP identity and project"
ACCT=$(gcloud config get-value account 2>/dev/null)
[ -n "$ACCT" ] && ok "active account: $ACCT" || bad "no active gcloud account"
gcloud projects describe "$PROJECT" --format="value(projectId)" &>/dev/null \
  && ok "project $PROJECT reachable" || bad "cannot reach project $PROJECT"
BILL=$(gcloud billing projects describe "$PROJECT" --format="value(billingEnabled)" 2>/dev/null)
[ "$BILL" = "True" ] && ok "billing enabled" || bad "billing NOT enabled"

echo
echo "3. Required APIs"
ENABLED=$(gcloud services list --enabled --project="$PROJECT" --format="value(config.name)" 2>/dev/null)
for api in compute.googleapis.com container.googleapis.com artifactregistry.googleapis.com; do
  grep -q "^${api}$" <<<"$ENABLED" && ok "$api" || bad "$api NOT enabled"
done
grep -q "^containerfilesystem.googleapis.com$" <<<"$ENABLED" \
  && ok "containerfilesystem.googleapis.com (phase 3 prerequisite)" \
  || warn "containerfilesystem.googleapis.com off — only needed for phase 3"

echo
echo "4. GPU quota in $REGION"
case "$GPU_TYPE" in
  nvidia-tesla-t4) Q_OND="NVIDIA_T4_GPUS"; Q_SPOT="PREEMPTIBLE_NVIDIA_T4_GPUS" ;;
  nvidia-l4)       Q_OND="NVIDIA_L4_GPUS"; Q_SPOT="PREEMPTIBLE_NVIDIA_L4_GPUS" ;;
  *)               Q_OND="UNKNOWN";        Q_SPOT="UNKNOWN" ;;
esac
QJSON=$(gcloud compute regions describe "$REGION" --project="$PROJECT" --format=json 2>/dev/null)
getq() { python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
print(next((int(q['limit']) for q in d['quotas'] if q['metric']=='$1'), 0))
" <<<"$QJSON"; }
L_OND=$(getq "$Q_OND"); L_SPOT=$(getq "$Q_SPOT")
L_PCPU=$(getq PREEMPTIBLE_CPUS); L_CPU=$(getq CPUS); L_SSD=$(getq SSD_TOTAL_GB)
[ "$L_OND" -ge 1 ] && ok "$Q_OND = $L_OND" || bad "$Q_OND = $L_OND (need >= 1)"
if [ "$USE_SPOT" = "true" ]; then
  [ "$L_SPOT" -ge 1 ] && ok "$Q_SPOT = $L_SPOT" || bad "$Q_SPOT = $L_SPOT (need >= 1)"
  [ "$L_PCPU" -ge 4 ] && ok "PREEMPTIBLE_CPUS = $L_PCPU" || bad "PREEMPTIBLE_CPUS = $L_PCPU"
fi
[ "$L_CPU" -ge 12 ] && ok "CPUS = $L_CPU" || warn "CPUS = $L_CPU (want >= 12)"
[ "$L_SSD" -ge 50 ] && ok "SSD_TOTAL_GB = $L_SSD" || warn "SSD_TOTAL_GB = $L_SSD"

echo
echo "5. $GPU_TYPE availability in $ZONE"
gcloud compute accelerator-types list --project="$PROJECT" --filter="zone:($ZONE)" \
  --format="value(name)" 2>/dev/null | grep -qx "$GPU_TYPE" \
  && ok "$GPU_TYPE offered in $ZONE" || bad "$GPU_TYPE NOT in $ZONE"
if [ "$GPU_TYPE" = "nvidia-l4" ] && [[ "$GPU_MACHINE" != g2-* ]]; then
  bad "nvidia-l4 requires a g2-* machine, got $GPU_MACHINE"
elif [ "$GPU_TYPE" = "nvidia-tesla-t4" ] && [[ "$GPU_MACHINE" != n1-* ]]; then
  bad "nvidia-tesla-t4 requires an n1-* machine, got $GPU_MACHINE"
else ok "machine type $GPU_MACHINE matches $GPU_TYPE"; fi

echo
echo "6. Collision check in shared project"
gcloud container clusters describe "$CLUSTER" --zone "$ZONE" --project "$PROJECT" &>/dev/null \
  && warn "cluster '$CLUSTER' ALREADY EXISTS — 03 will reuse it" \
  || ok "cluster name '$CLUSTER' is free"
gcloud artifacts repositories describe "$AR_REPO" --location=us --project="$PROJECT" &>/dev/null \
  && warn "AR repo '$AR_REPO' already exists — will be reused" \
  || ok "AR repo name '$AR_REPO' is free"
EXISTING=$(gcloud container clusters list --project="$PROJECT" --format="value(name)" 2>/dev/null | wc -l | tr -d ' ')
if [ "$EXISTING" -gt 0 ]; then
  warn "$PROJECT already has $EXISTING GKE cluster(s). We are NOT touching them:"
  gcloud container clusters list --project="$PROJECT" \
    --format="table[no-heading](name,location,status)" 2>/dev/null | sed 's/^/        /'
fi

echo
echo "7. Upstream repo"
[ -d "$REPO_DIR/k8s" ] && ok "repo present at $REPO_DIR" || bad "repo missing — run ./10-fetch-repo.sh"

echo
echo "=========================================================="
printf " %d passed, %d warnings, %d failures\n" "$PASS" "$WARN" "$FAIL"
echo "=========================================================="
[ "$FAIL" -gt 0 ] && { echo " Fix failures before running 02."; exit 1; }
echo " Preflight clean. Nothing created, nothing billed."
echo " Next:  ./02-build-images.sh"
echo
