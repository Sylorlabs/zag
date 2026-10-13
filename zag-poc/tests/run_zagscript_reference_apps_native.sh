#!/usr/bin/env bash
# Native-platform dispatcher for the frozen reference-application authorities.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
case "$(uname -s):$(uname -m)" in
    Linux:x86_64|Linux:amd64)
        exec bash "$root/tests/run_zagscript_reference_apps.sh"
        ;;
    Darwin:arm64)
        exec bash "$root/tests/run_zagscript_reference_apps_macos.sh"
        ;;
    *)
        echo "native reference-app aggregate has no authority for $(uname -s):$(uname -m)" >&2
        exit 2
        ;;
esac
