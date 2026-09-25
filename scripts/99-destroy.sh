#!/usr/bin/env bash
# 99-destroy.sh — tear everything down and PROVE nothing is left behind.
#
# Deleting the cluster alone is not enough. What quietly survives and keeps
# billing in a shared project:
#   - orphaned Persistent Disks from PVCs
#   - orphaned static IPs / forwarding rules from LoadBalancer Services
# This deletes in the right order, then audits.
set -uo pipefail
cd "$(dirname "$0")" && source ./00-config.sh

echo "=========================================================="
echo " TEARDOWN — $CLUSTER in $PROJECT / $ZONE"
echo "=========================================================="
read -rp "Delete the cluster and all POC resources? (type 'yes'): " YN
[ "$YN" = "yes" ] || { echo "Aborted."; exit 0; }

echo
echo "=== 1/4  Delete LoadBalancer Services and PVCs FIRST ==="
echo "    (lets GKE clean up forwarding rules and disks properly —"
echo "     deleting the cluster first can orphan them)"
if kubectl config current-context 2>/dev/null | grep -q "$CLUSTER"; then
  kubectl delete svc --all -n "$NAMESPACE" --timeout=120s 2>/dev/null || true
  kubectl delete pvc --all -n "$NAMESPACE" --timeout=120s 2>/dev/null || true
  sleep 20
else
  echo "    kubectl not pointed at $CLUSTER, skipping. Will audit at the end."
fi

echo
echo "=== 2/4  Delete GKE cluster (3-5 min) ==="
if gcloud container clusters describe "$CLUSTER" --zone "$ZONE" --project "$PROJECT" &>/dev/null; then
  gcloud container clusters delete "$CLUSTER" --zone "$ZONE" --project "$PROJECT" --quiet
else
  echo "    cluster already gone."
fi

echo
echo "=== 3/4  Artifact Registry ==="
read -rp "    Delete AR repo '$AR_REPO'? Keeping it saves a rebuild next time. (y/N): " AR
if [[ "$AR" =~ ^[Yy]$ ]]; then
  gcloud artifacts repositories delete "$AR_REPO" --location=us --project="$PROJECT" --quiet 2>/dev/null \
    && echo "    deleted." || echo "    could not delete."
else
  echo "    kept. ~\$0.02/month."
fi

echo
echo "=== 4/4  Orphan audit ==="
echo; echo "-- GKE clusters in $PROJECT --"
gcloud container clusters list --project="$PROJECT" --format="table(name,location,status)" 2>/dev/null || echo "  none"
echo; echo "-- Unattached disks in $ZONE (look for gke-${CLUSTER}-*) --"
gcloud compute disks list --project="$PROJECT" --filter="zone:($ZONE) AND -users:*" \
  --format="table(name,sizeGb,type,status)" 2>/dev/null || echo "  none"
echo; echo "-- Reserved static IPs in $REGION --"
gcloud compute addresses list --project="$PROJECT" --filter="region:($REGION)" \
  --format="table(name,address,status)" 2>/dev/null || echo "  none"
echo; echo "-- Forwarding rules in $REGION --"
gcloud compute forwarding-rules list --project="$PROJECT" --filter="region:($REGION)" \
  --format="table(name,IPAddress,target)" 2>/dev/null || echo "  none"
echo; echo "-- Instances still carrying our POC label --"
gcloud compute instances list --project="$PROJECT" \
  --filter="labels.purpose=ai-learning-poc" --format="table(name,zone,status)" 2>/dev/null || true

echo
echo "=========================================================="
echo " Teardown complete."
echo " Read the lists above. Anything named gke-${CLUSTER}-* still there is an"
echo " orphan and is still billing — delete it by hand."
echo
echo "   https://console.cloud.google.com/kubernetes/list?project=$PROJECT"
echo "   https://console.cloud.google.com/compute/disks?project=$PROJECT"
echo "=========================================================="
