#!/usr/bin/env bash
# 08-capture-grafana.sh — export the whole load-test story out of Grafana
# before the cluster is destroyed.
#
# Prometheus here uses emptyDir storage: when the pod dies, every data point
# dies with it. Capture first, tear down second.
#
# Produces, into ./artifacts/:
#   screenshots/  full-dashboard.png + one PNG per panel (Grafana render API)
#   data/         raw Prometheus series as JSON + CSV, so the repo has numbers
#                 and not only pictures
#   dashboard.json  the dashboard definition itself
set -uo pipefail
cd "$(dirname "$0")" && source ./00-config.sh

GRAFANA="http://localhost:3000"
PROM="http://localhost:9090"
OUT="./artifacts"
SHOTS="$OUT/screenshots"
DATA="$OUT/data"
mkdir -p "$SHOTS" "$DATA"

# Window: from just before run 1 to now. Override with FROM_ISO / TO_ISO.
FROM_ISO="${FROM_ISO:-2026-09-25T11:15:00Z}"
TO_ISO="${TO_ISO:-$(date -u +%FT%TZ)}"
FROM_MS=$(python3 -c "
import datetime;print(int(datetime.datetime.strptime('$FROM_ISO','%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp()*1000))")
TO_MS=$(python3 -c "
import datetime;print(int(datetime.datetime.strptime('$TO_ISO','%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp()*1000))")

echo "=========================================================="
echo " Capturing $FROM_ISO -> $TO_ISO"
echo " out: $OUT"
echo "=========================================================="

# ---------------------------------------------------- port-forwards
ensure_pf() { # name svc localport remoteport
  pgrep -f "port-forward svc/$2 $3:$4" >/dev/null && return
  nohup kubectl port-forward "svc/$2" "$3:$4" -n "$NAMESPACE" > "pf-$1.log" 2>&1 &
  sleep 6
}
ensure_pf grafana grafana 3000 3000
ensure_pf prom prometheus 9090 9090
echo "grafana:    $(curl -s -o /dev/null -w '%{http_code}' $GRAFANA/api/health)"
echo "prometheus: $(curl -s -o /dev/null -w '%{http_code}' $PROM/-/healthy)"

# ------------------------------------- give every panel a stable id
# The dashboard ships from a ConfigMap with no panel ids, so /render/d-solo
# has nothing to address. Assign 1..N and push it back before rendering.
echo
echo "=== 1/4  Assigning panel ids ==="
curl -s "$GRAFANA/api/dashboards/uid/llm-gateway" > "$DATA/dashboard-original.json"
python3 - <<'PYEOF'
import json
src=json.load(open('./artifacts/data/dashboard-original.json'))
d=src['dashboard']
for i,p in enumerate(d.get('panels',[]),start=1):
    p['id']=i
# The original is file-provisioned, so Grafana refuses to save it. Clone it
# under a fresh uid: the copy is API-owned and therefore writable, which is
# all we need to address panels with /render/d-solo.
d['uid']='llm-gateway-export'
d['title']='LLM Gateway (export)'
d.pop('id',None)
d.pop('version',None)
json.dump({"dashboard":d,"overwrite":True,"folderId":0,
           "message":"export copy with panel ids"},
          open('./artifacts/data/dashboard-ids.json','w'))
print(f"  cloned as uid=llm-gateway-export with ids 1..{len(d.get('panels',[]))}")
PYEOF
curl -s -u admin:admin -X POST "$GRAFANA/api/dashboards/db" \
  -H 'Content-Type: application/json' \
  -d @"$DATA/dashboard-ids.json" | python3 -c "
import json,sys
r=json.load(sys.stdin); print('  push:', r.get('status', r.get('message', r)))" 2>/dev/null

# ---------------------------------------------------- render panels
echo
echo "=== 2/4  Rendering panels ==="
render() { # panelId filename width height
  local url="$GRAFANA/render/d-solo/llm-gateway-export/llm-gateway-export?panelId=$1&from=$FROM_MS&to=$TO_MS&width=$3&height=$4&tz=Asia%2FRiyadh"
  curl -s -u admin:admin --max-time 120 -o "$SHOTS/$2" "$url"
  local sz; sz=$(wc -c < "$SHOTS/$2" | tr -d ' ')
  if [ "$sz" -lt 5000 ]; then echo "  [thin] $2 (${sz}B) — check renderer"; else echo "  [ ok ] $2 (${sz}B)"; fi
}

curl -s -u admin:admin "$GRAFANA/api/dashboards/uid/llm-gateway-export" | python3 -c "
import json,sys,re
d=json.load(sys.stdin)['dashboard']
for p in d.get('panels',[]):
    t=(p.get('title') or 'panel').strip()
    slug=re.sub(r'[^a-z0-9]+','-',t.lower()).strip('-')[:60] or 'text'
    print(f\"{p['id']}|{slug}|{p.get('type')}\")
" > "$DATA/panels.txt"

while IFS='|' read -r pid slug ptype; do
  [ "$ptype" = "text" ] && continue
  render "$pid" "$(printf '%02d' "$pid")-${slug}.png" 1400 500
done < "$DATA/panels.txt"

echo
echo "  full dashboard..."
curl -s -u admin:admin --max-time 180 -o "$SHOTS/00-full-dashboard.png" \
  "$GRAFANA/render/d/llm-gateway/llm-gateway?from=$FROM_MS&to=$TO_MS&width=1600&height=3000&tz=Asia%2FRiyadh&kiosk"
echo "  [ ok ] 00-full-dashboard.png ($(wc -c < "$SHOTS/00-full-dashboard.png" | tr -d ' ')B)"

# ------------------------------------------- raw data out of Prometheus
echo
echo "=== 3/4  Exporting raw Prometheus series ==="
FROM_S=$((FROM_MS/1000)); TO_S=$((TO_MS/1000))
q() { # name promql
  curl -s --max-time 60 -G "$PROM/api/v1/query_range" \
    --data-urlencode "query=$2" \
    --data-urlencode "start=$FROM_S" --data-urlencode "end=$TO_S" \
    --data-urlencode "step=15" -o "$DATA/$1.json"
  python3 - "$DATA/$1.json" "$DATA/$1.csv" <<'PY'
import json,sys,datetime
src,dst=sys.argv[1],sys.argv[2]
try: d=json.load(open(src))
except Exception: print(f"  [fail] {src}"); raise SystemExit
rs=d.get('data',{}).get('result',[])
rows=0
with open(dst,'w') as f:
    f.write("timestamp_utc,series,value\n")
    for s in rs:
        label=','.join(f"{k}={v}" for k,v in sorted(s['metric'].items()) if k!='__name__') or (s['metric'].get('__name__','series'))
        for ts,val in s['values']:
            f.write(f"{datetime.datetime.fromtimestamp(float(ts),datetime.timezone.utc).isoformat()},\"{label}\",{val}\n"); rows+=1
print(f"  {dst.split('/')[-1]}: {len(rs)} series, {rows} points")
PY
}
q queue-depth            'redis_key_size{key="inference_queue"}'
q pod-replicas           'kube_deployment_status_replicas{namespace="llm-gateway"}'
q gpu-nodes              'count(kube_node_status_capacity{resource="nvidia_com_gpu"} > 0) or vector(0)'
q node-count             'count(kube_node_info)'
q gpu-util               'DCGM_FI_DEV_GPU_UTIL'
q gpu-power              'DCGM_FI_DEV_POWER_USAGE'
q gpu-mem                'DCGM_FI_DEV_FB_USED'
q gpu-temp               'DCGM_FI_DEV_GPU_TEMP'
q vllm-running           'vllm:num_requests_running'
q vllm-waiting           'vllm:num_requests_waiting'
q vllm-kvcache           'vllm:kv_cache_usage_perc'
q vllm-e2e-latency-p95   'histogram_quantile(0.95, sum(rate(vllm:e2e_request_latency_seconds_bucket[2m])) by (le))'
q vllm-gen-tokens        'rate(vllm:generation_tokens_total[1m])'
q vllm-prompt-tokens     'rate(vllm:prompt_tokens_total[1m])'
q vllm-ttft-p95          'histogram_quantile(0.95, sum(rate(vllm:time_to_first_token_seconds_bucket[2m])) by (le))'

# ---------------------------------------------------------- inventory
echo
echo "=== 4/4  Inventory ==="
ls -la "$SHOTS" | tail -n +2 | awk '{printf "  %-52s %s\n",$9,$5}'
echo
du -sh "$OUT" 2>/dev/null
echo
echo "Done: $(cd "$OUT" && pwd)"
