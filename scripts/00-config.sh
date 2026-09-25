#!/usr/bin/env bash
# 00-config.sh — single source of truth. Every script sources this.

# ---------------------------------------------------------------- GCP target
export PROJECT="YOUR_PROJECT_ID"
export REGION="us-east1"
export ZONE="us-east1-d"                  # T4 + L4 both available here
export CLUSTER="llm-gateway-poc"
export NAMESPACE="llm-gateway"

# ------------------------------------------------------------------ hardware
export GPU_TYPE="nvidia-tesla-t4"         # or: nvidia-l4
export GPU_MACHINE="n1-standard-4"        # L4 needs g2-standard-4 instead
export USE_SPOT="false"        # PREEMPTIBLE_CPUS=0 in this project, so spot cannot run
export CPU_MACHINE="e2-standard-4"

# --------------------------------------------------------------------- model
export MODEL_ID="Qwen/Qwen2.5-1.5B-Instruct"
export PVC_SIZE="10Gi"

# ------------------------------------------------------------------ registry
export AR_REPO="llm-gateway-poc"
export REGISTRY="us-docker.pkg.dev/${PROJECT}/${AR_REPO}"

# dockerhub = GKE pulls vLLM direct, nothing through your Mac (use for run 1)
# ar        = mirrored to Artifact Registry, REQUIRED before secondary boot disk
export VLLM_IMAGE_SOURCE="ar"
export VLLM_IMAGE_DOCKERHUB="vllm/vllm-openai:latest"
export VLLM_IMAGE_AR="${REGISTRY}/vllm-openai:latest"

# Empty for run 1 on purpose: run 1 measures the unoptimized baseline.
export VLLM_DISK_IMAGE="vllm-node-cache-20260925"

# ------------------------------------------------------------------- scaling
export KEDA_LIST_LENGTH="5"               # per-replica target, NOT a threshold
export WORKER_MAX_REPLICAS="2"
export GPU_POOL_MAX_NODES="1"             # hard ceiling on GPU spend

export GCP_LABELS="purpose=ai-learning-poc,owner=fahad,delete-after=session"
export REPO_DIR="${REPO_DIR:-$HOME/ai-learning/gpu-autoscale-poc/gpu-autoscale-inference}"

if [ "$USE_SPOT" = "true" ]; then export SPOT_FLAG="--spot"; else export SPOT_FLAG=""; fi

# --------------------------------------------------------------- cost table
#   GKE control plane            $0.10/hr
#   e2-standard-4                $0.134/hr
#   n1-standard-4 + T4  spot     ~$0.16/hr     on-demand ~$0.54/hr
#   g2-standard-4 + L4  spot     ~$0.28/hr     on-demand ~$0.85/hr
#   LoadBalancer                 ~$0.025/hr
# Idle (GPU at zero) ~$0.26/hr   Under load (T4 spot) ~$0.42/hr

echo "config: project=$PROJECT zone=$ZONE cluster=$CLUSTER gpu=$GPU_TYPE spot=$USE_SPOT" >&2
