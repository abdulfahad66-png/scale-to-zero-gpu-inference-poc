#!/usr/bin/env bash
# 90-cost-check.sh — READ-ONLY. What is running and what it burns.
# Run this before walking away from the session.
set -uo pipefail
cd "$(dirname "$0")" && source ./00-config.sh

echo "=========================================================="
echo " COST CHECK — $PROJECT / $CLUSTER      $(date)"
echo "=========================================================="
BURN=0; add() { BURN=$(python3 -c "print(round($BURN + $1, 4))"); }

if gcloud container clusters describe "$CLUSTER" --zone "$ZONE" --project "$PROJECT" &>/dev/null; then
  echo; echo "Cluster: RUNNING"
  echo "  GKE control plane ................ \$0.10/hr"; add 0.10
else
  echo; echo "Cluster: NOT FOUND — nothing from this POC is billing. You are clean."
  exit 0
fi

echo; echo "Nodes:"
kubectl get nodes -o custom-columns='NAME:.metadata.name,POOL:.metadata.labels.cloud\.google\.com/gke-nodepool,MACHINE:.metadata.labels.node\.kubernetes\.io/instance-type,GPU:.status.capacity.nvidia\.com/gpu' 2>/dev/null

CPU_N=$(kubectl get nodes -l cloud.google.com/gke-nodepool=default-pool --no-headers 2>/dev/null | wc -l | tr -d ' ')
GPU_N=$(kubectl get nodes -l cloud.google.com/gke-nodepool=gpu-pool     --no-headers 2>/dev/null | wc -l | tr -d ' ')

echo
printf "  CPU nodes  x%s ..................... " "$CPU_N"
C=$(python3 -c "print(round($CPU_N * 0.134, 4))"); echo "\$$C/hr"; add "$C"

if [ "$GPU_TYPE" = "nvidia-l4" ]; then
  [ "$USE_SPOT" = "true" ] && RATE=0.28 || RATE=0.85
else
  [ "$USE_SPOT" = "true" ] && RATE=0.16 || RATE=0.54
fi
printf "  GPU nodes  x%s (%s spot=%s) ... " "$GPU_N" "$GPU_TYPE" "$USE_SPOT"
G=$(python3 -c "print(round($GPU_N * $RATE, 4))"); echo "\$$G/hr"; add "$G"

LB=$(kubectl get svc -n "$NAMESPACE" -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -c . || echo 0)
printf "  LoadBalancers x%s ................. " "$LB"
L=$(python3 -c "print(round($LB * 0.025, 4))"); echo "\$$L/hr"; add "$L"

PVC=$(kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
printf "  PVCs x%s (10Gi pd-balanced) ....... \$0.0014/hr\n" "$PVC"; add 0.0014

echo "  ------------------------------------------------"
printf "  TOTAL ............................ \$%s/hr\n" "$BURN"
printf "                                     \$%s/day if left running\n" "$(python3 -c "print(round($BURN*24,2))")"
echo "  ------------------------------------------------"

if [ "$GPU_N" -gt 0 ]; then
  echo
  echo "  A GPU node is UP. With an empty queue it should disappear on its own"
  echo "  in ~10 min. If it stays much longer, something is pinning it — look"
  echo "  for pods tolerating the GPU taint."
fi
echo; echo "  Teardown: ./99-destroy.sh"
