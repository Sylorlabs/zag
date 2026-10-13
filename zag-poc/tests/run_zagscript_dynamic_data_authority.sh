#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash tests/run_database_drivers.sh
case "$(uname -s):$(uname -m)" in Darwin:arm64) bash tests/run_macos_dylib.sh; bash tests/run_macos_object.sh; bash tests/run_reference_dynamic_plugin_macos.sh ;; Linux:x86_64) bash tests/run_dynamic_abi.sh; bash tests/run_reference_dynamic_plugin.sh ;; *) exit 1 ;; esac
bash tests/run_reference_sqlite_http_service.sh
echo 'ZagScript dynamic/data authority: PASS'
