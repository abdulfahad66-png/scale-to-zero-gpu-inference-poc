# Results — every measurement and how it was taken

All times Asia/Riyadh (UTC+3). Single run, 2026-09-25.

## Environment

| | |
|---|---|
| Cluster | GKE Standard 1.35.8-gke.1036000, zonal, `us-east1-d` |
| CPU pool | 1× `e2-standard-4`, autoscaling 1–2 |
| GPU pool | 0–1× `n1-standard-4` + 1× NVIDIA T4, **on-demand** |
| GPU taint | `nvidia.com/gpu=present:NoSchedule` |
| Model | `Qwen/Qwen2.5-1.5B-Instruct` on `vllm/vllm-openai:latest` (8.73 GB) |
| vLLM flags | `--max-model-len 4096 --gpu-memory-utilization 0.8 --enforce-eager` |
| Model storage | 10 Gi PVC, `standard-rwo` (CSI, pd-balanced) |
| KEDA | Redis list `inference_queue`, `listLength: 5`, worker max 2, vLLM max 1 |
| Load | 30 concurrent POSTs with an identical ~50-token prompt |

Spot was unavailable: `PREEMPTIBLE_CPUS = 0` in this project. On-demand also
gives a cleaner baseline — no preemption noise.

---

## Run 1 — baseline, image pulled over the network

`VLLM_DISK_IMAGE=""`. Raw log: `artifacts/evidence/runs/run1-baseline.log`.

| Clock | T+ | Event |
|---|---|---|
| 14:22:12 | 0 s | 30 requests fired; vLLM 0, worker 0, GPU nodes 0 |
| 14:22:24 | 12 s | KEDA activates; vLLM pod `Pending` |
| 14:23:08 | 56 s | `TriggeredScaleUp gpu-pool 0→1` |
| 14:24:1x | ~120 s | node Ready, NVIDIA driver, device plugin, pod scheduled |
| 14:24:1x → 14:30:27 | 373.6 s | **image pull** |
| 14:30:27 | 495 s | container started |
| 14:34:01 | **709 s** | **readiness probe passes — cold start** |
| 14:34:23 | 731 s | queue drained, 30/30 complete |
| ~14:38:30 | ~976 s | KEDA scales both Deployments to 0 (300 s cooldown) |
| 14:49:00 | 1608 s | Cluster Autoscaler begins node deletion (600 s unneeded) |
| 14:51:24 | **1752 s** | **GPU node gone — $0/hr** |

### Scheduler's own account of the wait

From `kubectl describe pod`, in order:

```
0/1 nodes are available: 1 node(s) didn't match Pod's node affinity/selector
TriggeredScaleUp: [{gpu-pool 0->1 (max: 1)}]
0/2 nodes: 1 didn't match affinity, 1 had untolerated taint(s)
0/2 nodes: 1 Insufficient nvidia.com/gpu
0/2 nodes: 1 didn't match PersistentVolume's node affinity
NotTriggerScaleUp: 1 max node group size reached
Scheduled → SuccessfulAttachVolume → Pulling image
```

Three of these are worth pausing on:

- **`Insufficient nvidia.com/gpu` while the node shows `Ready`.** `nvidia.com/gpu`
  is an extended resource advertised by the NVIDIA device plugin DaemonSet.
  Until the driver installs, the node's GPU capacity is `0`. Node readiness and
  GPU usability are different things.
- **`didn't match PersistentVolume's node affinity`.** The PVC is `ReadWriteOnce`
  on a zonal PD, bound when the model-init Job ran. The vLLM pod must land in
  that zone. Fine in a single-zone cluster; a real constraint in a regional one.
- **`NotTriggerScaleUp: max node group size reached`.** `GPU_POOL_MAX_NODES=1`
  doing its job as a spend ceiling.

---

## Run 2 — GKE Secondary Boot Disk

`VLLM_DISK_IMAGE="vllm-node-cache-20260925"`, GPU pool recreated, vLLM image
repointed at Artifact Registry so the reference matches what is cached.
Raw log: `artifacts/evidence/runs/run2-bootdisk.log`.

| Clock | T+ | Event |
|---|---|---|
| 15:19:29 | 0 s | 30 requests fired, everything at zero |
| 15:19:41 | 12 s | KEDA activates |
| 15:19:50 | 21 s | `TriggeredScaleUp gpu-pool 0→1` |
| 15:21:51 | 142 s | GPU node Ready |
| 15:22:32 | 183 s | pod scheduled |
| 15:22:32 → 15:22:45 | **13.3 s** | **image pull from local disk** |
| 15:22:45 | 196 s | container started |
| 15:26:12 | **403 s** | **readiness probe passes** |
| 15:26:34 | 425 s | queue drained |

### Phase-by-phase

| Phase | Run 1 | Run 2 | Δ |
|---|---|---|---|
| KEDA activation | ~12 s | ~12 s | — |
| CA provisions node | 65 s | 130 s | +65 s |
| Node ready → scheduled | ~44 s | ~44 s | — |
| **Image pull** | **373.6 s** | **13.3 s** | **−360.3 s** |
| vLLM boot → ready | 213 s | 195 s | −18 s |
| **Total** | **709 s** | **403 s** | **−306 s (−43%)** |

The +65 s on node provisioning is GCE variance, unrelated to the change.
Normalising for it puts run 2 at ~338 s — the same figure the upstream author
measured independently on different hardware.

---

## Run 3 — warm node, cold pod

Not planned. KEDA's cooldown fired between tests, the GPU node was still up, and
a single queued job brought vLLM back. The accidental control.

| | |
|---|---|
| Pod created | 15:31:19 |
| Image pull | **0.64 s** (already in that node's containerd store) |
| Readiness | 15:34:38 |
| **Total** | **200 s** |

This isolates vLLM's own startup. Node present, GPU present, image present,
model on an attached disk — and still 200 s. It corroborates run 2's 195 s
vLLM-boot figure from a completely different direction.

---

## Run 4 — fully warm

30 requests into a running vLLM.

```
T+3s   queue=26
T+8s   queue=20
T+13s  queue=13
T+19s  queue=4
T+24s  queue=0
```

**24 s** for 30 requests, 2 workers, one T4.

---

## The image pull, isolated

| Source | Time | Rate | Speedup |
|---|---|---|---|
| Docker Hub over network | 373.6 s | ~23 MB/s | 1× |
| Secondary boot disk (local pd-SSD) | 13.3 s | ~656 MB/s | **28×** |
| Same node's containerd store | 0.64 s | — | **583×** |

All three are the same 8,730,576,300-byte image. Evidence:
`artifacts/evidence/events-image-pull.txt`.

23 MB/s is not the network — the NIC does multi-Gbps. containerd pulls three
layers concurrently and decompresses each, which is CPU-bound on 4 vCPUs. The
setting is visible in the builder VM's containerd config dump:

```
MaxConcurrentDownloads:3
```

GKE exposes no knob for it. That is why the fix is "don't pull".

**Caveat:** the cache only covers images placed in it. `dcgm-exporter` was not,
and still took **1 m 9.8 s** for 819 MB on the same node.

---

## vLLM internals

From the pod's boot log:

```
Loading weights took 17.39 seconds
Model loading took 2.98 GiB memory and 27.65 seconds
Available KV cache memory: 8.28 GiB
GPU KV cache size: 310,016 tokens
Maximum concurrency for 4,096 tokens per request: 75.69x
WARNING FlashInfer top-p/top-k sampling unavailable:
        unsupported compute capability 7.5; falling back
```

- **8.28 GiB KV cache** is `--gpu-memory-utilization 0.8` at work: 16 GB × 0.8
  = 12.8 GB reserved, minus 2.98 GB of weights.
- **75.69× concurrency** is PagedAttention as a number.
- **Compute capability 7.5** — T4 is Turing, too old for FlashInfer. An L4 (8.9)
  would take that path.
- **27.65 s** for PVC → VRAM, against upstream's ~2.5 min. The difference is
  `standard-rwo` (pd-balanced SSD) versus `standard` (pd-standard HDD).

Of the 195–200 s vLLM startup, only ~28 s is the model load. The rest is
`import torch`, CUDA context, KV-cache profiling and JIT warmup.

---

## Scale-down

Two independent timers, both observed:

| Stage | Trigger | Delay | Observed |
|---|---|---|---|
| Pods → 0 | KEDA `cooldownPeriod` | 300 s | ~14:34 → ~14:38:30 |
| Node → 0 | CA `scale-down-unneeded-time` | 600 s | ~14:38:30 → 14:49:00 start, 14:51:24 gone |

The node's taints during deletion show the two-stage cordon:

```
DeletionCandidateOfClusterAutoscaler   PreferNoSchedule   ← considering
ToBeDeletedByClusterAutoscaler         NoSchedule         ← committed
node.kubernetes.io/unschedulable                          ← cordoned
node.kubernetes.io/not-ready           NoExecute          ← evicting
```

Only DaemonSet pods remained on the node at that point — `kube-proxy`, `netd`,
`fluentbit`, `nvidia-gpu-device-plugin`, `dcgm-exporter`. Cluster Autoscaler
ignores DaemonSets when deciding whether a node is unneeded. A single ordinary
pod tolerating the GPU taint would have pinned the node indefinitely.

---

## Cost

| State | Rate |
|---|---|
| Idle (control plane + CPU node + LB) | ~$0.26/hr |
| GPU node up (on-demand T4) | ~$0.78/hr |
| Full ~30 min cycle | ~$0.35 |
| **Whole session, incl. one wrong-project cluster** | **~$2.10** |

---

## Raw data

`artifacts/data/` — Prometheus `query_range`, 15 s step, as JSON and CSV:

| File | Query |
|---|---|
| `queue-depth` | `redis_key_size{key="inference_queue"}` |
| `pod-replicas` | `kube_deployment_status_replicas{namespace="llm-gateway"}` |
| `gpu-nodes` | `count(kube_node_status_capacity{resource="nvidia_com_gpu"} > 0)` |
| `node-count` | `count(kube_node_info)` |
| `gpu-util` | `DCGM_FI_DEV_GPU_UTIL` |
| `gpu-power` | `DCGM_FI_DEV_POWER_USAGE` |
| `gpu-mem` | `DCGM_FI_DEV_FB_USED` |
| `gpu-temp` | `DCGM_FI_DEV_GPU_TEMP` |
| `vllm-running` / `vllm-waiting` | `vllm:num_requests_running` / `_waiting` |
| `vllm-kvcache` | `vllm:kv_cache_usage_perc` |
| `vllm-gen-tokens` / `vllm-prompt-tokens` | `rate(vllm:*_tokens_total[1m])` |
| `vllm-ttft-p95` | `histogram_quantile(0.95, …time_to_first_token…)` |
| `vllm-e2e-latency-p95` | `histogram_quantile(0.95, …e2e_request_latency…)` |

`artifacts/evidence/` — 45 files: Kubernetes events (all, KEDA-only,
Cluster-Autoscaler-only, image-pull-only), pod logs, applied manifests, GKE
cluster and node-pool YAML, the secondary boot disk image description, and the
region's GPU quota at the time of the run.

## Threats to validity

- **Single run per scenario.** Node provisioning alone varied by 65 s between
  runs, so treat sub-minute differences as noise. The 360 s image-pull delta is
  far outside that.
- **One model, one prompt, one GPU.** Nothing here says how a 70B model or a
  mixed workload behaves.
- **Run 3 was accidental**, not a designed control — though that arguably makes
  it better evidence, since nothing was tuned for it.
- **Grafana annotations** in the upstream dashboard hardcode the original
  author's run times. The header panel in `artifacts/screenshots/` was rewritten
  with this run's timeline before capture; the annotation legend toggles at the
  top of the dashboard are still upstream's and are not ours.
