#!/usr/bin/env bash
# 05-smoke-test.sh — fire enough requests to cross the KEDA trigger, then watch
# the two-layer scale-up live. This is the money shot of the whole POC.
#
# Expected timeline from cold zero, T4 spot, NO secondary boot disk:
#   T+0s     requests queued, everything at zero
#   T+0-30s  KEDA activates: worker 0->N, vllm 0->1
#   T+35s    vllm pod Pending (nothing in the cluster has a GPU)
#   T+40s    Cluster Autoscaler: TriggeredScaleUp gpu-pool 0->1
#   T+2-3m   GPU node Ready, NVIDIA driver installed
#   T+8-10m  8GB image pulled   <-- the bottleneck this project exists to fix
#   T+10-12m readiness probe passes, queue drains
# That total is the BASELINE. Phase 3 cuts it to ~5 min.
set -euo pipefail
cd "$(dirname "$0")" && source ./00-config.sh

GATEWAY_IP="${1:-$(cat ./.gateway-ip 2>/dev/null || true)}"
[ -z "$GATEWAY_IP" ] && GATEWAY_IP=$(kubectl get svc gateway -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
[ -n "$GATEWAY_IP" ] || { echo "ERROR: no gateway IP. Pass it as arg 1."; exit 1; }

REQUESTS="${REQUESTS:-30}"
LOGDIR="./data/smoke-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$LOGDIR"
T0=$(date +%s); t() { printf "T+%-5ss" "$(( $(date +%s) - T0 ))"; }

echo "=== 0. Confirm we are actually at zero ==="
echo "  GPU nodes:       $(kubectl get nodes -l cloud.google.com/gke-nodepool=gpu-pool --no-headers 2>/dev/null | wc -l | tr -d ' ')"
echo "  vllm replicas:   $(kubectl get deploy vllm   -n "$NAMESPACE" -o jsonpath='{.status.replicas}' 2>/dev/null || echo 0)"
echo "  worker replicas: $(kubectl get deploy worker -n "$NAMESPACE" -o jsonpath='{.status.replicas}' 2>/dev/null || echo 0)"
echo
echo "=== 0b. Gateway health ==="
curl -sS --max-time 10 "http://${GATEWAY_IP}/health"; echo

echo
echo "=== 1. Firing $REQUESTS requests at $GATEWAY_IP ==="
> "$LOGDIR/job-ids.txt"
for i in $(seq 1 "$REQUESTS"); do
  curl -sS -X POST "http://${GATEWAY_IP}/generate" -H 'Content-Type: application/json' \
    -d '{"prompt":"Explain in detail how Kubernetes event-driven autoscaling works, covering KEDA queue triggers and Cluster Autoscaler node provisioning for GPU workloads."}' \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('job_id',''))" >> "$LOGDIR/job-ids.txt" &
done
wait
echo "    queued $(wc -l < "$LOGDIR/job-ids.txt" | tr -d ' ') jobs"

kubectl get events -n "$NAMESPACE" --watch-only \
  -o custom-columns='TIME:.lastTimestamp,TYPE:.type,REASON:.reason,OBJ:.involvedObject.name,MSG:.message' \
  > "$LOGDIR/k8s-events.log" 2>&1 & W1=$!
kubectl get events -A --watch-only --field-selector reason=TriggeredScaleUp \
  > "$LOGDIR/node-scaleup.log" 2>&1 & W2=$!
trap 'kill $W1 $W2 2>/dev/null || true' EXIT

echo
echo "=== 2. Watching the chain. Ctrl-C to stop. ==="
printf "%-9s %-6s %-7s %-7s %-9s %s\n" "ELAPSED" "QUEUE" "WORKER" "VLLM" "GPUNODES" "VLLM POD"
VLLM_READY_AT=""
for i in $(seq 1 240); do
  Q=$(kubectl exec -n "$NAMESPACE" deploy/redis -c redis -- redis-cli LLEN inference_queue 2>/dev/null || echo "?")
  WK=$(kubectl get deploy worker -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  VL=$(kubectl get deploy vllm   -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  GN=$(kubectl get nodes -l cloud.google.com/gke-nodepool=gpu-pool --no-headers 2>/dev/null | wc -l | tr -d ' ')
  PS=$(kubectl get pods -n "$NAMESPACE" -l app=vllm --no-headers 2>/dev/null | awk '{print $3" "$2}' | head -1)
  printf "%-9s %-6s %-7s %-7s %-9s %s\n" "$(t)" "${Q:-0}" "${WK:-0}" "${VL:-0}" "$GN" "${PS:-none}"
  echo "$(date -u +%FT%TZ) queue=${Q:-0} worker=${WK:-0} vllm=${VL:-0} gpunodes=$GN" >> "$LOGDIR/timeline.log"
  if [ "${VL:-0}" -ge 1 ] && [ -z "$VLLM_READY_AT" ]; then
    VLLM_READY_AT=$(( $(date +%s) - T0 ))
    echo "  >>> vLLM READY. COLD START = ${VLLM_READY_AT}s" | tee -a "$LOGDIR/timeline.log"
  fi
  if [ "${Q:-1}" = "0" ] && [ -n "$VLLM_READY_AT" ]; then
    echo "  >>> QUEUE DRAINED at T+$(( $(date +%s) - T0 ))s" | tee -a "$LOGDIR/timeline.log"
    break
  fi
  sleep 15
done

echo
echo "=== 3. Sample result ==="
JID=$(head -1 "$LOGDIR/job-ids.txt")
curl -sS "http://${GATEWAY_IP}/result/${JID}" | head -c 600; echo

echo
echo "=== 4. Cluster Autoscaler node events ==="
head -10 "$LOGDIR/node-scaleup.log" 2>/dev/null

echo
echo "=== 5. KEDA scaling events ==="
kubectl get events -n "$NAMESPACE" --field-selector reason=KEDAScaleTargetActivated \
  -o custom-columns='TIME:.lastTimestamp,OBJ:.involvedObject.name,MSG:.message' 2>/dev/null | head

echo
echo "=========================================================="
echo " Cold start (queue -> vLLM ready): ${VLLM_READY_AT:-not reached}s"
echo " Logs: $LOGDIR"
echo "=========================================================="
echo
echo "Now leave it idle and watch scale-to-zero:"
echo "  pods to 0  after ~5 min   (KEDA cooldownPeriod 300s)"
echo "  node to 0  after ~10 min more (CA scale-down-unneeded-time)"
echo "  watch -n 30 'kubectl get nodes,pods -n $NAMESPACE'"
echo
echo "Grafana:  kubectl port-forward svc/grafana 3000:3000 -n $NAMESPACE"
echo "Teardown: ./99-destroy.sh"
