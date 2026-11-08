#!/usr/bin/env bash
set -euo pipefail

echo "=========================================================="
echo "Jules J15 Reproduction Script: BENCHMARK-ALG-LADDER-v1"
echo "=========================================================="

SOURCE_SHA=$(git rev-parse HEAD 2>/dev/null || echo "UNKNOWN_GIT_SHA")
echo "Source SHA: ${SOURCE_SHA}"
echo "Current Branch: $(git branch --show-current 2>/dev/null || echo 'UNKNOWN_BRANCH')"
echo "Python version: $(python3 --version)"
echo "Host info: $(uname -a)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo ""
echo "--- Running Benchmark Harness Smoke Test ---"
python3 dev_harness.py

echo ""
echo "--- Running Baseline Smoke Test ---"
python3 baseline.py

echo ""
echo "--- Running CTAM Substrate Smoke Test ---"
python3 ctam_substrate.py

echo ""
echo "--- Running Evaluation Experiments & Causal Controls ---"
python3 run_experiments.py

echo ""
echo "--- Results Summary ---"
python3 -c "
import json
with open('results.json') as f:
    res = json.load(f)
s = res['summary']
print(f\"VERDICT: {s['verdict']}\")
print(f\"L2 Efficiency Improvement: {s['L2_efficiency_improvement']*100:.1f}%\")
print(f\"L3 Efficiency Improvement: {s['L3_efficiency_improvement']*100:.1f}%\")
print(f\"Total VM Steps: {s['total_vm_steps']}\")
print(f\"Total Evaluations: {s['total_evaluations']}\")
print(f\"Retained State Bytes: {s['retained_state_bytes']}\")
"

echo "Reproduction script finished successfully."
