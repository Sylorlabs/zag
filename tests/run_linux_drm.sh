#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/.."
ZNC="${ZNC:-./znc}"
"$ZNC" tests/linux_drm.zag -o /tmp/zag_linux_drm_test --analyze-strict
/tmp/zag_linux_drm_test
