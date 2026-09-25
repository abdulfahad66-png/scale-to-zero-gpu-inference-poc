#!/usr/bin/env bash
# 04-deploy-app.sh — render upstream manifests with our values and apply them.
#
# We never edit the cloned repo. Everything renders into ./rendered/ so you can
# diff what we changed against upstream and re-run cleanly.
#
# Four real fixes, each one a bug we would otherwise hit:
#   1. PVC storageClassName: upstream says "standard". Recent GKE has no such
#      class (default is standard-rwo) — the PVC sits Pending forever with no
#      obvious error. We detect the real default.
#   2. Images repointed at our registry, not the author's.
#   3. dcgm-exporter nodeSelector hardcodes nvidia-tesla-t4 — switch GPU_TYPE
#      to L4 and the DaemonSet silently never schedules, every GPU panel blank.
#   4. GPU toleration + nodeSelector patched onto vLLM to match the pool taint.
set -euo pipefail
cd "$(dirname "$0")" && source ./00-config.sh

[ -d "$REPO_DIR/k8s" ] || { echo "ERROR: repo missing. Run ./10-fetch-repo.sh"; exit 1; }
kubectl config current-context | grep -q "$CLUSTER" || {
  echo "ERROR: kubectl not pointed at $CLUSTER. Run:"
  echo "  gcloud container clusters get-credentials $CLUSTER --zone $ZONE --project $PROJECT"
  exit 1; }

RENDER="./rendered"; rm -rf "$RENDER"; mkdir -p "$RENDER"
cp "$REPO_DIR"/k8s/*.yaml "$RENDER"/
cp "$REPO_DIR"/monitoring/*.yaml "$RENDER"/ 2>/dev/null || true

echo "=== 1/7  Storage class ==="
DEFAULT_SC=$(kubectl get storageclass -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' \
             | awk -F'\t' '$2=="true"{print $1; exit}')
[ -z "$DEFAULT_SC" ] && DEFAULT_SC="standard-rwo"
echo "    cluster default StorageClass: $DEFAULT_SC"
kubectl get storageclass
sed -i.bak "s|storageClassName: standard$|storageClassName: ${DEFAULT_SC}|" "$RENDER/vllm-pvc.yaml"
sed -i.bak "s|storage: 10Gi|storage: ${PVC_SIZE}|" "$RENDER/vllm-pvc.yaml"

echo
echo "=== 2/7  dcgm-exporter node selector -> $GPU_TYPE ==="
if [ -f "$RENDER/dcgm-exporter.yaml" ]; then
  sed -i.bak "s|cloud.google.com/gke-accelerator: \"nvidia-tesla-t4\"|cloud.google.com/gke-accelerator: \"${GPU_TYPE}\"|" \
    "$RENDER/dcgm-exporter.yaml"
  grep -n "gke-accelerator" "$RENDER/dcgm-exporter.yaml" | sed 's/^/    /'
fi

echo
echo "=== 3/7  Namespace and base manifests ==="
kubectl apply -f "$RENDER/namespace.yaml"
rm -f "$RENDER"/*.bak
kubectl apply -n "$NAMESPACE" \
  -f "$RENDER/redis.yaml" \
  -f "$RENDER/gateway-deployment.yaml" \
  -f "$RENDER/gateway-service.yaml" \
  -f "$RENDER/vllm-service.yaml" \
  -f "$RENDER/worker-deployment.yaml" \
  -f "$RENDER/vllm-deployment.yaml"

echo
echo "=== 4/7  Point deployments at our images ==="
if [ "$VLLM_IMAGE_SOURCE" = "ar" ]; then VLLM_IMG="$VLLM_IMAGE_AR"; else VLLM_IMG="$VLLM_IMAGE_DOCKERHUB"; fi
kubectl set image deployment/gateway gateway="${REGISTRY}/gateway:latest" -n "$NAMESPACE"
kubectl set image deployment/worker  worker="${REGISTRY}/worker:latest"   -n "$NAMESPACE"
kubectl set image deployment/vllm    vllm="$VLLM_IMG"                     -n "$NAMESPACE"
kubectl set env  deployment/worker   MODEL_ID="$MODEL_ID" VLLM_URL="http://vllm:8000" -n "$NAMESPACE"
echo "    gateway -> ${REGISTRY}/gateway:latest"
echo "    worker  -> ${REGISTRY}/worker:latest"
echo "    vllm    -> $VLLM_IMG"

echo
echo "=== 5/7  PVC and model download job ==="
kubectl apply -f "$RENDER/vllm-pvc.yaml" -n "$NAMESPACE"
kubectl apply -f "$RENDER/vllm-model-init-job.yaml" -n "$NAMESPACE"
echo "    downloading $MODEL_ID (~3.5GB) onto the PVC. 5-8 minutes."
echo "    Runs on the CPU node. No GPU is provisioned by this step."
if ! kubectl wait --for=condition=complete job/vllm-model-init -n "$NAMESPACE" --timeout=900s; then
  echo
  echo "    Model init did not complete. Check:"
  echo "      kubectl logs job/vllm-model-init -n $NAMESPACE"
  echo "      kubectl describe pvc vllm-model-weights -n $NAMESPACE"
  exit 1
fi

echo
echo "=== 6/7  GPU toleration + nodeSelector on vLLM ==="
cat > "$RENDER/vllm-gpu-patch.yaml" <<EOF
spec:
  template:
    spec:
      enableServiceLinks: false
      tolerations:
        - key: "nvidia.com/gpu"
          operator: "Exists"
          effect: "NoSchedule"
      nodeSelector:
        cloud.google.com/gke-accelerator: "${GPU_TYPE}"
EOF
kubectl patch deployment vllm -n "$NAMESPACE" --type=strategic --patch-file="$RENDER/vllm-gpu-patch.yaml"

echo
echo "=== 7/7  Monitoring, then KEDA ScaledObjects ==="
kubectl apply -f "$RENDER/prometheus.yaml" -n "$NAMESPACE"
[ -f "$RENDER/dcgm-exporter.yaml" ] && kubectl apply -f "$RENDER/dcgm-exporter.yaml" -n "$NAMESPACE"

# Fix: upstream pairs grafana with the image-renderer sidecar but never sets
# GF_RENDERING_RENDERER_TOKEN. Older grafana:latest only warned; current
# versions refuse to start ("default renderer_token is not allowed").
# Classic :latest drift - the manifest didn't change, the image did.
GRAFANA_TOKEN="poc-renderer-$(openssl rand -hex 8)"
kubectl set env deployment/grafana -n "$NAMESPACE" -c grafana  GF_RENDERING_RENDERER_TOKEN="$GRAFANA_TOKEN" >/dev/null
kubectl set env deployment/grafana -n "$NAMESPACE" -c renderer AUTH_TOKEN="$GRAFANA_TOKEN" >/dev/null
echo "    grafana renderer token set"

# ScaledObjects go on LAST, deliberately. Applied earlier, KEDA sees the empty
# queue and scales both Deployments to zero mid-setup, making it look broken.
kubectl apply -f "$RENDER/worker-keda-scaledobject.yaml" -n "$NAMESPACE"
kubectl apply -f "$RENDER/vllm-keda-scaledobject.yaml"   -n "$NAMESPACE"

kubectl rollout status deployment/redis   -n "$NAMESPACE" --timeout=180s
kubectl rollout status deployment/gateway -n "$NAMESPACE" --timeout=180s

echo
echo "=== Waiting for LoadBalancer IP ==="
for i in $(seq 1 40); do
  GATEWAY_IP=$(kubectl get svc gateway -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  [ -n "$GATEWAY_IP" ] && break
  printf "    ... %d/40\r" "$i"; sleep 10
done
echo

echo "=========================================================="
kubectl get all -n "$NAMESPACE"
echo "=========================================================="
echo
echo "KEDA ScaledObjects (READY=True, ACTIVE=False at idle):"
kubectl get scaledobject -n "$NAMESPACE"
echo
if [ -n "${GATEWAY_IP:-}" ]; then
  echo "$GATEWAY_IP" > ./.gateway-ip
  echo "Gateway:  http://$GATEWAY_IP   (saved to ./.gateway-ip)"
else
  echo "LB IP not assigned yet: kubectl get svc gateway -n $NAMESPACE -w"
fi
echo
echo "SECURITY: that IP is public and /generate has no auth. Anyone who finds"
echo "it can make you provision a GPU node. Do not leave this running unattended."
echo
echo "Next:  ./05-smoke-test.sh"
