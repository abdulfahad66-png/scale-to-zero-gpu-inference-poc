#!/usr/bin/env bash
# 10-capture-cluster-evidence.sh — pull everything else out of the cluster
# before teardown. Pod logs, events, manifests, node and quota facts.
#
# All of this dies with the cluster. The screenshots prove what happened;
# these files prove WHY, and let anyone reading the repo verify the numbers
# instead of taking them on trust.
set -uo pipefail
cd "$(dirname "$0")" && source ./00-config.sh

EV="./artifacts/evidence"; mkdir -p "$EV"
say() { echo "  -> $1"; }

echo "=== Kubernetes state ==="
kubectl get all -n "$NAMESPACE" -o wide          > "$EV/k8s-all.txt" 2>&1;            say k8s-all.txt
kubectl get scaledobject,hpa -n "$NAMESPACE" -o yaml > "$EV/keda-scaledobjects.yaml" 2>&1; say keda-scaledobjects.yaml
kubectl get nodes -o wide                        > "$EV/nodes.txt" 2>&1;              say nodes.txt
kubectl describe nodes                           > "$EV/nodes-describe.txt" 2>&1;     say nodes-describe.txt
kubectl get pvc,pv -n "$NAMESPACE" -o wide       > "$EV/storage.txt" 2>&1;            say storage.txt
kubectl get storageclass                         > "$EV/storageclasses.txt" 2>&1;     say storageclasses.txt

echo "=== Events (the autoscaling story in raw form) ==="
kubectl get events -n "$NAMESPACE" \
  --sort-by=.metadata.creationTimestamp \
  -o custom-columns='TIME:.lastTimestamp,TYPE:.type,REASON:.reason,OBJECT:.involvedObject.name,MESSAGE:.message' \
  > "$EV/events-all.txt" 2>&1; say events-all.txt
grep -E "KEDAScaleTarget" "$EV/events-all.txt" > "$EV/events-keda.txt" 2>/dev/null; say events-keda.txt
kubectl get events -A --sort-by=.metadata.creationTimestamp \
  -o custom-columns='TIME:.lastTimestamp,REASON:.reason,OBJECT:.involvedObject.name,MESSAGE:.message' \
  | grep -E "TriggeredScaleUp|ScaleDown|NotTriggerScaleUp" > "$EV/events-cluster-autoscaler.txt" 2>&1
say events-cluster-autoscaler.txt
grep -E "Pulling|Pulled|Scheduled|FailedScheduling" "$EV/events-all.txt" > "$EV/events-image-pull.txt" 2>/dev/null
say events-image-pull.txt

echo "=== Pod logs ==="
for app in vllm worker gateway; do
  kubectl logs -n "$NAMESPACE" -l "app=$app" --tail=3000 --all-containers \
    > "$EV/logs-$app.txt" 2>&1 || true
  say "logs-$app.txt ($(wc -l < "$EV/logs-$app.txt" | tr -d ' ') lines)"
done
kubectl logs -n keda -l app.kubernetes.io/name=keda-operator --tail=1500 \
  > "$EV/logs-keda-operator.txt" 2>&1 || true; say logs-keda-operator.txt

echo "=== GCP facts ==="
gcloud container clusters describe "$CLUSTER" --zone "$ZONE" --project "$PROJECT" \
  --format=yaml > "$EV/gke-cluster.yaml" 2>&1; say gke-cluster.yaml
gcloud container node-pools list --cluster "$CLUSTER" --zone "$ZONE" --project "$PROJECT" \
  --format=yaml > "$EV/gke-nodepools.yaml" 2>&1; say gke-nodepools.yaml
gcloud compute images describe "$VLLM_DISK_IMAGE" --project "$PROJECT" \
  --format=yaml > "$EV/secondary-boot-disk-image.yaml" 2>&1 || true; say secondary-boot-disk-image.yaml
gcloud compute regions describe "$REGION" --project "$PROJECT" --format=json 2>/dev/null \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
rows=[q for q in d['quotas'] if 'GPU' in q['metric'] or q['metric'] in ('CPUS','PREEMPTIBLE_CPUS','SSD_TOTAL_GB')]
print(f\"{'METRIC':42} {'LIMIT':>10} {'USAGE':>8}\")
for q in sorted(rows,key=lambda x:x['metric']):
    print(f\"{q['metric']:42} {q['limit']:>10.0f} {q['usage']:>8.0f}\")
" > "$EV/gcp-quota-$REGION.txt" 2>&1; say "gcp-quota-$REGION.txt"

echo "=== Rendered manifests actually applied ==="
mkdir -p "$EV/manifests"
cp ./rendered/*.yaml "$EV/manifests/" 2>/dev/null || true
say "manifests/ ($(ls -1 "$EV/manifests" 2>/dev/null | wc -l | tr -d ' ') files)"

echo "=== Run logs from the smoke tests ==="
mkdir -p "$EV/runs"
cp -R ./data/* "$EV/runs/" 2>/dev/null || true
cp smoke.log  "$EV/runs/run1-baseline.log"   2>/dev/null || true
cp smoke2.log "$EV/runs/run2-bootdisk.log"   2>/dev/null || true
cp nodecache2.log "$EV/runs/disk-image-build.log" 2>/dev/null || true
cp cluster3.log "$EV/runs/cluster-create.log" 2>/dev/null || true
say "runs/ ($(ls -1 "$EV/runs" 2>/dev/null | wc -l | tr -d ' ') entries)"

echo
du -sh ./artifacts
echo "Evidence: $(cd "$EV" && pwd)"
