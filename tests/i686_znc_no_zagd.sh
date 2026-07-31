#!/usr/bin/env bash
# Release-authority adapter: keep background planning out of the measured
# target proof without changing normal project policy.
set -euo pipefail
exec "${ZNC_REAL:-./znc}" "$@" --no-zagd
