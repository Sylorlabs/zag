#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash tests/run_zagscript_async.sh
case "$(uname -s):$(uname -m)" in
    Darwin:arm64)
        bash tests/run_macos_concurrency_services.sh
        ;;
    Linux:x86_64)
        bash tests/run_cancel_token.sh
        bash tests/run_channel_cancel.sh
        bash tests/run_linux_concurrency_services.sh
        bash tests/run_reference_concurrent_file_indexer.sh
        ;;
    *) exit 1 ;;
esac
echo 'ZagScript concurrency authority: PASS'
