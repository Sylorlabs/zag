#!/usr/bin/env bash
# Complete local verification gate for the implemented Zag Script/zagd release
# plus the documented Linux/i686 subset.
#
# This command is intentionally expensive. It rebuilds the self-hosted compiler
# to a byte-identical fixpoint, executes every first-release suite, repeats the
# fixpoint in a bounded memory cgroup, exercises the documented ELF32/i386
# subset, and records a fresh 30-run benchmark report. Every phase is sequential so this
# gate cannot create several compiler rebuilds that compete for workstation RAM.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "════ Zag Script complete local master gate ════"
echo "Heavy work is sequential; no compiler stages run concurrently."
echo "MemorySwapMax=${ZAG_SELFHOST_SWAP_MAX_BYTES:-0} bytes for self-host proof stages."

echo
echo "── [1/7] fixed-point self-host bootstrap"
/usr/bin/time -f 'bootstrap elapsed=%E peak_rss_kib=%M' bash bootstrap.sh

echo
echo "── [2/7] byte-identical pure-Zag bootstrap reproduction"
/usr/bin/time -f 'repro elapsed=%E peak_rss_kib=%M' \
    bash tests/check_native_bootstrap_repro.sh

echo
echo "── [3/7] remaining existing v1 compatibility authority"
/usr/bin/time -f 'v1-compat elapsed=%E peak_rss_kib=%M' \
    bash tests/run_v1_compatibility_gate.sh

echo
echo "── [4/7] Linux x86-64 Zag Script release gate"
/usr/bin/time -f 'release elapsed=%E peak_rss_kib=%M' \
    bash tests/run_zagscript_release_gate.sh

echo
echo "── [5/7] authoritative Linux/i686 target boundary"
/usr/bin/time -f 'i686-authority elapsed=%E peak_rss_kib=%M' \
    bash tests/run_i686_release_gate.sh

echo
echo "── [6/7] bounded three-stage memory regression"
# The memory gate refuses to run without a working user cgroup and active
# earlyoom. A skip is intentionally a master-gate failure: it means the
# workstation-safety claim was not proven in this environment.
bash tests/run_native_memory_regression.sh --probe
ZAG_RUN_HEAVY_MEMORY_GATE=1 \
    /usr/bin/time -f 'memory-gate elapsed=%E coordinator_peak_rss_kib=%M' \
    bash tests/run_native_memory_regression.sh

echo
echo "── [7/7] fresh reproducible 30-run benchmark report"
RUNS=30 /usr/bin/time -f 'benchmarks elapsed=%E peak_rss_kib=%M' \
    bash benchmarks/run_zagscript.sh

echo
echo "════ Zag Script complete local master gate: PASS ════"
