#!/usr/bin/env bash
# 03-create-cluster.sh — GKE cluster, CPU pool, GPU pool (0 nodes), KEDA, kube-state-metrics.
#
# THIS STARTS BILLING. Control plane ~$0.10/hr, CPU node ~$0.13/hr.
# The GPU pool starts at ZERO nodes and costs nothing until a pod demands a
# GPU — which is the entire point of the exercise.
# Takes 8-10 minutes.
set -euo pipefail
cd "$(dirname "$0")" && source ./00-config.sh

echo "=========================================================="
echo " About to create billable resources in $PROJECT"
echo "   cluster:   $CLUSTER  ($ZONE)"
echo "   cpu pool:  1x $CPU_MACHINE"
echo "   gpu pool:  0-$GPU_POOL_MAX_NODES x $GPU_MACHINE + $GPU_TYPE  spot=$USE_SPOT"
echo "   idle burn: ~\$0.26/hr    under load: ~\$0.42/hr"
echo "=========================================================="
read -rp "Proceed? (y/N): " YN
[[ "$YN" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

echo
echo "=== 1/5  GKE cluster ==="
if gcloud container clusters describe "$CLUSTER" --zone "$ZONE" --project "$PROJECT" &>/dev/null; then
  echo "    exists, reusing."
else
  gcloud container clusters create "$CLUSTER" \
    --project "$PROJECT" --zone "$ZONE" \
    --num-nodes 1 --machine-type "$CPU_MACHINE" --disk-size 50 \
    --release-channel regular \
    --enable-autoscaling --min-nodes 1 --max-nodes 2 \
    --labels "$GCP_LABELS" \
    --addons HorizontalPodAutoscaling,HttpLoadBalancing \
    --workload-pool "${PROJECT}.svc.id.goog"
fi

echo
echo "=== 2/5  GPU node pool (starts at 0 nodes) ==="
if gcloud container node-pools describe gpu-pool --cluster "$CLUSTER" --zone "$ZONE" --project "$PROJECT" &>/dev/null; then
  echo "    exists, reusing."
else
  SBD_FLAGS=""
  if [ -n "$VLLM_DISK_IMAGE" ]; then
    echo "    with secondary boot disk: $VLLM_DISK_IMAGE"
    SBD_FLAGS="--enable-image-streaming --secondary-boot-disk=disk-image=global/images/${VLLM_DISK_IMAGE},mode=CONTAINER_IMAGE_CACHE"
  else
    echo "    NO secondary boot disk — this run measures the unoptimized baseline."
  fi
  gcloud container node-pools create gpu-pool \
    --cluster "$CLUSTER" --project "$PROJECT" --zone "$ZONE" \
    --machine-type "$GPU_MACHINE" \
    --accelerator "type=${GPU_TYPE},count=1,gpu-driver-version=default" \
    --disk-size 100 --disk-type pd-balanced \
    $SPOT_FLAG \
    --num-nodes 0 --min-nodes 0 --max-nodes "$GPU_POOL_MAX_NODES" --enable-autoscaling \
    --node-taints="nvidia.com/gpu=present:NoSchedule" \
    $SBD_FLAGS
fi

echo
echo "=== 3/5  kubectl credentials ==="
gcloud container clusters get-credentials "$CLUSTER" --zone "$ZONE" --project "$PROJECT"
kubectl config current-context

echo
echo "=== 4/5  KEDA ==="
if kubectl get namespace keda &>/dev/null; then
  echo "    already installed."
else
  helm repo add kedacore https://kedacore.github.io/charts 2>/dev/null || true
  helm repo update kedacore
  helm install keda kedacore/keda --namespace keda --create-namespace --wait --timeout 5m
fi
kubectl get pods -n keda

echo
echo "=== 5/5  kube-state-metrics ==="
if kubectl get deployment kube-state-metrics -n kube-system &>/dev/null; then
  echo "    already installed."
else
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
  helm repo update prometheus-community
  helm install kube-state-metrics prometheus-community/kube-state-metrics \
    --namespace kube-system --wait --timeout 5m
fi

echo
echo "=== Cluster ready ==="
kubectl get nodes -o wide
echo
echo "GPU node count (should be ZERO right now):"
kubectl get nodes -l cloud.google.com/gke-nodepool=gpu-pool --no-headers 2>/dev/null | wc -l
echo
echo "Next:  ./04-deploy-app.sh"
echo "Burning now: ~\$0.26/hr.  Teardown: ./99-destroy.sh"
