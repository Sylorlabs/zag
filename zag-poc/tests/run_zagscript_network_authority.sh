#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash tests/run_network_foundation.sh
bash tests/run_http_websocket_foundation.sh
case "$(uname -s):$(uname -m)" in Darwin:arm64) bash tests/run_reference_tls_http_service_macos.sh ;; Linux:x86_64) bash tests/run_reference_tls_http_service.sh ;; *) exit 1 ;; esac
echo 'ZagScript network authority: PASS'
