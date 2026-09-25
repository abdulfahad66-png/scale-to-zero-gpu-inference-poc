#!/usr/bin/env bash
# 10-fetch-repo.sh — clone the upstream repo. Read-only against GCP. Free.
set -euo pipefail
cd "$(dirname "$0")" && source ./00-config.sh

if [ -d "$REPO_DIR/.git" ]; then
  echo "Repo already present at $REPO_DIR"
  git -C "$REPO_DIR" log --oneline -1
  exit 0
fi

mkdir -p "$(dirname "$REPO_DIR")"
echo "Cloning gpu-autoscale-inference into $REPO_DIR ..."
git clone https://github.com/adityonugrohoid/gpu-autoscale-inference.git "$REPO_DIR"
echo
echo "Done. Note: scripts under $REPO_DIR/scripts/ are the AUTHOR's and hardcode"
echo "his project and region. We do not run those. Our 01..99 scripts are the ones to use."
