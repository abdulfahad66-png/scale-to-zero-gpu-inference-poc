# Findings — six things that broke, and why

Every one of these stopped the run. None is documented anywhere the upstream
repo points to. Most are drift: the repo did not change, the world under it did.

Ordered by how long each took to diagnose.

---

## 1. `gke-disk-image-builder` is pinned to an archived Debian

**Symptom.** The build dies 21 seconds in with one unhelpful line:

```
[secondary-disk-image] Error running workflow: step "wait-on-image-creation"
run error: WaitForInstancesSignal FailureMatch found for
"secondary-disk-image-instance": "startup-script-url exit status 1"
```

The real error is not in that output at all. It is in the builder VM's
serial-port log, streamed to the GCS bucket the tool creates:

```
Err:2 https://deb.debian.org/debian-security bullseye-security/main amd64
      containerd amd64 1.4.13~ds1-1~deb11u6
  404  Not Found
E: Failed to fetch .../containerd_1.4.13%7eds1-1%7edeb11u6_amd64.deb  404
Failed to start containerd.service: Unit containerd.service not found.
sudo: ctr: command not found
containerd is not running. Please rerun the tool to try it again.
```

**Root cause.** `imager.go` hardcodes the builder VM's boot image in two places:

```go
SourceImage: "projects/debian-cloud/global/images/debian-11-bullseye-v20230912"
```

A September 2023 Debian 11 image. Debian 11 is archived; its startup script runs
`apt install containerd`, apt resolves a version whose `.deb` has been rotated
out of the security pool, the fetch 404s, containerd never installs, and
everything after that collapses. `apt update` runs first and does not help —
the index is current, the pool file is gone.

**Fix.** Point the builder at a current Debian:

```bash
sed -i "s|debian-11-bullseye-v20230912|debian-12-bookworm-v20260921|g" imager.go
```

`scripts/07-build-node-cache.sh` clones the tool into `./tools-dib` and applies
this automatically, so the patch is visible and repeatable rather than a manual
step you forget.

**How to spot it.** When a Daisy workflow fails with `startup-script-url exit
status 1`, the message is a summary, not a cause. Go to the GCS path the tool
prints and read `logs/*-serial-port1.log`.

---

## 2. `roles/editor` cannot install KEDA on GKE

**Symptom.** Helm fails with nine near-identical errors:

```
clusterroles.rbac.authorization.k8s.io "keda-operator" is forbidden:
User "..." cannot patch resource "clusterroles" in API group
"rbac.authorization.k8s.io" at the cluster scope: requires one of
["container.clusterRoles.update"] permission(s) in Cloud IAM
```

**Root cause.** GKE deliberately withholds RBAC write permissions from
`roles/editor`. If an Editor could create ClusterRoles, they could mint
themselves a cluster-admin role and project-level IAM would be decorative. It
is an escalation guard, not an oversight.

KEDA's chart creates 4 ClusterRoles and 5 ClusterRoleBindings — it needs them to
drive HPA and to register an external metrics API server. There is no reduced
install.

The usual workaround is a bootstrap `cluster-admin` binding:

```bash
kubectl create clusterrolebinding cluster-admin-binding \
  --clusterrole=cluster-admin --user=<you>
```

That needs `container.clusterRoleBindings.create`, which is the same permission
you do not have. Chicken and egg.

**Fix.** You need `roles/container.admin` on the project. You cannot grant it to
yourself — `setIamPolicy` is denied to Editor:

```
ERROR: ... does not have permission to access projects instance
[<project>:setIamPolicy]: Policy update access denied.
```

**Consequence.** This decided which project the POC ran in. The first-choice
project had excellent GPU quota (T4 = 16) but only Editor access. The project
we used has less quota (T4 = 4) but Owner, so KEDA installs.

**Check it in five seconds, before you build anything:**

```bash
kubectl auth can-i create clusterrolebinding
```

Note that `kubectl auth can-i '*' '*' --all-namespaces` answers `yes` for an
Editor and is misleading. Ask the specific question.

---

## 3. macOS bash 3.2 versus `set -u` and empty arrays

**Symptom.**

```
./03-create-cluster.sh: line 49: SBD_FLAGS[@]: unbound variable
```

Thrown right after printing the GPU pool banner, so the cluster exists but the
node pool does not.

**Root cause.** macOS still ships bash **3.2.57** (2007 — a GPLv3 licensing
decision). Expanding an empty array under `set -u` is an error there and
perfectly legal in bash 4+:

```bash
SBD_FLAGS=()
gcloud ... "${SBD_FLAGS[@]}"   # bash 3.2 + set -u → unbound variable
```

The script would have run on any Linux machine. This is not GCP's fault or the
upstream repo's — it was my own code, and it is a trap for anyone writing
"portable" shell on a Mac.

**Fix.** Use a plain string and let word-splitting do the work, exactly as the
`--spot` flag already did:

```bash
SBD_FLAGS=""
[ -n "$VLLM_DISK_IMAGE" ] && SBD_FLAGS="--enable-image-streaming --secondary-boot-disk=..."
gcloud ... $SBD_FLAGS
```

`"${ARR[@]+"${ARR[@]}"}"` also works but reads badly. The alternative is
`#!/opt/homebrew/bin/bash`, which assumes Homebrew bash is installed.

---

## 4. `--release-channel None` is closed to new customers

**Symptom.**

```
ERROR: (gcloud.container.clusters.create) ResponseError: code=400,
In alignment with the deprecation, not enrolling clusters in a release channel
is now only allowed for existing customers.
```

**Root cause.** The upstream script uses `--release-channel None
--no-enable-autoupgrade` for a defensible reason: a POC cluster should not
auto-upgrade in the middle of a benchmark. Google has since restricted that to
projects that already used it.

**Fix.** `--release-channel regular`, and drop `--no-enable-autoupgrade` (not
valid with a channel). Regular is well past the 1.30.1 minimum that Secondary
Boot Disk requires — we got 1.35.8.

**Cost of the failure:** nothing. It failed before creating anything.

---

## 5. `grafana:latest` stopped starting

**Symptom.** `grafana` pod in `CrashLoopBackOff`, 1/2 containers ready, seven
restarts. The renderer sidecar is healthy; Grafana itself exits:

```
logger=rendering level=error msg="Using the default [rendering]renderer_token
is not allowed for production settings, set it to another value."
Error: ✗ failed to start rendering service: Using the default
[rendering]renderer_token is not allowed for production settings
```

**Root cause.** The manifest pairs Grafana with `grafana-image-renderer` but
never sets `GF_RENDERING_RENDERER_TOKEN`. Older Grafana logged a warning;
current Grafana refuses to boot. The manifest did not change — the image behind
`:latest` did.

**Fix.** A matching token on both containers:

```bash
TOKEN="poc-renderer-$(openssl rand -hex 8)"
kubectl set env deployment/grafana -c grafana  GF_RENDERING_RENDERER_TOKEN="$TOKEN" -n llm-gateway
kubectl set env deployment/grafana -c renderer AUTH_TOKEN="$TOKEN"                  -n llm-gateway
```

Applied automatically in `scripts/04-deploy-app.sh`.

**The general lesson.** `:latest` in a manifest means the manifest has no fixed
meaning. Every image here — `grafana`, `vllm-openai`, `redis_exporter`,
`prometheus` — is `:latest`. Pin them if you want the repo to work in a year.

---

## 6. The PVC storage class: not a crash, a slowdown

**Symptom.** None. Everything works.

**Root cause.** Upstream requests `storageClassName: standard`. On GKE 1.35 that
class still exists, but it is the legacy in-tree `kubernetes.io/gce-pd`
provisioner backing **pd-standard** — a spinning disk. The cluster default,
`standard-rwo`, is CSI-backed **pd-balanced** SSD.

The model is read from that disk into VRAM on every single cold start.

**Measured difference.** Upstream reports ~2.5 min for PVC → VRAM. On
pd-balanced: **27.65 s**.

**Fix.** Detect the cluster's real default rather than hardcoding a name:

```bash
DEFAULT_SC=$(kubectl get storageclass -o jsonpath='...is-default-class=="true"...')
```

**Why it belongs on this list.** A silent 2-minute regression on the critical
path is worse than a crash. A crash you fix in ten minutes; this you carry
forever and blame on "GPUs being slow to start".

---

## Two more, not failures but worth knowing

### GKE now ships its own DCGM exporter

```
gke-managed-system/dcgm-exporter-kg8dr   Running
llm-gateway/dcgm-exporter-vp4rq          Running
```

Two exporters scraping the same GPU. Harmless, redundant, and the repo's
`monitoring/dcgm-exporter.yaml` predates the managed one. On current GKE, prefer
Google Cloud Managed Service for Prometheus and delete the DaemonSet.

Related trap: the DaemonSet hardcodes
`cloud.google.com/gke-accelerator: "nvidia-tesla-t4"`. Switch `GPU_TYPE` to L4
and it silently never schedules — every GPU panel stays blank with no error
anywhere. `scripts/04-deploy-app.sh` substitutes the configured type.

### The boot-disk cache only covers what you put in it

On the same node, same run:

```
vllm-openai     8.73 GB   pulled in 13.297s   ← in the cache
dcgm-exporter   819 MB    pulled in 1m9.815s  ← not in the cache
```

`dcgm-exporter` took **five times longer** than the image 10× its size. In
production, every image on the node-startup critical path belongs in the disk
image, not just the obvious big one.

---

## Meta-observation

Five of the six are **drift**, not bugs: a deprecated flag, an EOL base image, a
`:latest` tag that moved, an IAM model that tightened, a storage class that was
superseded. The repo was correct when written.

Anything that provisions cloud infrastructure has a shelf life measured in
months. The defence is a preflight that checks reality instead of assuming it —
which is why `scripts/01-preflight.sh` is read-only, runs first, and verifies
tools, IAM, APIs, quota, GPU-in-zone and machine-family compatibility before a
single billable resource exists.

---

## 7. Teardown orphaned a Persistent Disk anyway

**Symptom.** The teardown script's own audit, after deleting everything:

```
-- Unattached disks in us-east1-d --
NAME                                      SIZE_GB  TYPE         STATUS
pvc-80d22f30-4d9f-428c-918b-aa39b50cf254  10       pd-balanced  READY
```

The cluster was gone. The disk was not.

**Root cause.** The script deletes PVCs *before* the cluster precisely to avoid
this — the CSI driver is supposed to see the PVC removed and delete the backing
PD, since the reclaim policy is `Delete`. But PD deletion is asynchronous, and
the cluster teardown took the CSI controller down before it finished. The PVC
object disappeared; the disk it pointed at did not.

Correct ordering is necessary and not sufficient.

**Fix.** Delete it by hand:

```bash
gcloud compute disks delete pvc-80d22f30-... --zone us-east1-d --project <p> --quiet
```

**Why this is the most practically useful finding here.** It is 10 GB of
pd-balanced — about **$0.40/month**. Nobody notices $0.40. Run this POC twenty
times over a year and you have twenty invisible disks and a line item nobody
can explain.

Scale-to-zero is a cost story, and the cost story does not end when the GPU node
disappears. The audit step exists for exactly this, and on its first real run it
earned its place.

**What made cleanup easy.** GKE propagated our node-pool labels onto the PD:

```
purpose=ai-learning-poc
owner=fahad
delete-after=session
goog-k8s-cluster-name=llm-gateway-poc
goog-k8s-node-pool-name=gpu-pool
```

So orphans from this POC are findable with one query, long after the cluster
that created them is gone:

```bash
gcloud compute disks list --filter="labels.purpose=ai-learning-poc AND -users:*"
```

Label everything you create in a shared project. It is the difference between a
cleanup query and an archaeology project.
