#!/usr/bin/env bash
# 09-fix-export-dashboard.sh — rewrite the export dashboard's header panel with
# THIS run's real timeline, then re-render at a sane height.
#
# Why: the upstream dashboard ships a static text panel whose legend hardcodes
# the original author's run times (19:00:56 phase 1, a Spot preemption at
# 19:06:28, and so on). None of that is ours — we ran on-demand and never had a
# preemption. Left as-is, every screenshot in the repo would be captioned with
# someone else's experiment.
set -uo pipefail
cd "$(dirname "$0")" && source ./00-config.sh

GRAFANA="http://localhost:3000"
OUT="./artifacts"; SHOTS="$OUT/screenshots"; DATA="$OUT/data"
mkdir -p "$SHOTS" "$DATA"

FROM_ISO="${FROM_ISO:-2026-09-25T11:15:00Z}"
TO_ISO="${TO_ISO:-$(date -u +%FT%TZ)}"
FROM_MS=$(python3 -c "import datetime;print(int(datetime.datetime.strptime('$FROM_ISO','%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp()*1000))")
TO_MS=$(python3 -c "import datetime;print(int(datetime.datetime.strptime('$TO_ISO','%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp()*1000))")

pgrep -f "port-forward svc/grafana" >/dev/null || { nohup kubectl port-forward svc/grafana 3000:3000 -n "$NAMESPACE" > pf-grafana.log 2>&1 & sleep 6; }

echo "=== Rewriting header panel with this run's timeline ==="
python3 - <<'PYEOF'
import json
d=json.load(open('./artifacts/data/dashboard-original.json'))['dashboard']
for i,p in enumerate(d.get('panels',[]),start=1):
    p['id']=i

html = """
<div style="font-family:ui-sans-serif,system-ui,sans-serif;line-height:1.55">
<div style="font-size:15px;font-weight:600;margin-bottom:2px">
  Scale-to-Zero GPU Inference &mdash; measured run, 2026-09-25
</div>
<div style="font-size:12px;opacity:.75;margin-bottom:8px">
  GKE 1.35.8 &middot; us-east1-d &middot; n1-standard-4 + NVIDIA T4 (on-demand)
  &middot; Qwen2.5-1.5B-Instruct on vLLM &middot; times shown Asia/Riyadh
</div>
<table style="font-size:12px;border-collapse:collapse">
<tr style="opacity:.7"><th align="left" style="padding:2px 14px 2px 0">#</th>
<th align="left" style="padding:2px 14px 2px 0">Run</th>
<th align="left" style="padding:2px 14px 2px 0">Window</th>
<th align="left" style="padding:2px 14px 2px 0">Cold start</th>
<th align="left" style="padding:2px 0">Image pull</th></tr>
<tr><td style="padding:2px 14px 2px 0">1</td>
<td style="padding:2px 14px 2px 0">Baseline &mdash; no image cache</td>
<td style="padding:2px 14px 2px 0">14:22:12 &rarr; 14:51:24</td>
<td style="padding:2px 14px 2px 0"><b>709 s</b></td>
<td style="padding:2px 0"><b>373.6 s</b> (8.73 GB over network)</td></tr>
<tr><td style="padding:2px 14px 2px 0">2</td>
<td style="padding:2px 14px 2px 0">GKE Secondary Boot Disk</td>
<td style="padding:2px 14px 2px 0">15:19:29 &rarr; 15:26:34</td>
<td style="padding:2px 14px 2px 0"><b>403 s</b> (&minus;43%)</td>
<td style="padding:2px 0"><b>13.3 s</b> (local disk, 28&times; faster)</td></tr>
<tr><td style="padding:2px 14px 2px 0">3</td>
<td style="padding:2px 14px 2px 0">Warm node, cold pod</td>
<td style="padding:2px 14px 2px 0">15:31:19 &rarr; 15:34:38</td>
<td style="padding:2px 14px 2px 0"><b>200 s</b></td>
<td style="padding:2px 0">none &mdash; already on node</td></tr>
<tr><td style="padding:2px 14px 2px 0">4</td>
<td style="padding:2px 14px 2px 0">Fully warm (30 requests)</td>
<td style="padding:2px 14px 2px 0">15:34:50 &rarr; 15:35:14</td>
<td style="padding:2px 14px 2px 0"><b>24 s</b> to drain</td>
<td style="padding:2px 0">none</td></tr>
</table>
<div style="font-size:11px;opacity:.7;margin-top:8px">
  Scale-down, run 1: queue empty 14:34 &rarr; KEDA set both Deployments to 0 at
  ~14:38 (300 s cooldown) &rarr; Cluster Autoscaler deleted the GPU node at
  14:51:24 (600 s unneeded timer). No Spot preemption occurred: this run used
  on-demand capacity.
</div>
</div>
"""

for p in d.get('panels',[]):
    if p.get('type')=='text':
        p.setdefault('options',{})
        p['options']['mode']='html'
        p['options']['content']=html
        p['title']=''
        g=p.setdefault('gridPos',{})
        g['h']=7
        break

d['uid']='llm-gateway-export'
d['title']='LLM Gateway (export)'
d.pop('id',None); d.pop('version',None)
json.dump({"dashboard":d,"overwrite":True,"folderId":0,
           "message":"header rewritten with this run's timeline"},
          open('./artifacts/data/dashboard-ids.json','w'))
print("  header panel rewritten")
PYEOF

curl -s -u admin:admin -X POST "$GRAFANA/api/dashboards/db" \
  -H 'Content-Type: application/json' -d @"$DATA/dashboard-ids.json" \
  | python3 -c "import json,sys;r=json.load(sys.stdin);print('  push:',r.get('status',r.get('message',r)))"

echo
echo "=== Re-rendering full dashboard at correct height ==="
for H in 1100; do
  curl -s -u admin:admin --max-time 180 -o "$SHOTS/00-full-dashboard.png" \
    "$GRAFANA/render/d/llm-gateway-export/llm-gateway-export?from=$FROM_MS&to=$TO_MS&width=1800&height=$H&tz=Asia%2FRiyadh&kiosk"
  echo "  00-full-dashboard.png ($(wc -c < "$SHOTS/00-full-dashboard.png" | tr -d ' ')B) at 1800x$H"
done

echo
echo "=== Re-rendering the four story panels larger ==="
big() { curl -s -u admin:admin --max-time 120 -o "$SHOTS/$2" \
  "$GRAFANA/render/d-solo/llm-gateway-export/llm-gateway-export?panelId=$1&from=$FROM_MS&to=$TO_MS&width=1600&height=560&tz=Asia%2FRiyadh"
  echo "  $2 ($(wc -c < "$SHOTS/$2" | tr -d ' ')B)"; }
big 2  hero-1-queue-depth.png
big 4  hero-2-pod-replicas.png
big 5  hero-3-cluster-nodes-gpu.png
big 6  hero-4-gpu-utilization.png

echo
echo "Done."
