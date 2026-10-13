#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

compiler=${ZNC:-./znc}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-zir-portable.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

"$compiler" selfhost/zir_authority_test.zag -o "$tmp/zir-authority" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp/zir-authority"

grep -q 'lower_zir_program_mode_cpu(zir_authority' selfhost/native/znc.zag
grep -q 'lower_zir_program_mode_cpu(hot_zir_authority' selfhost/native/znc.zag
direct_lower_calls=$(sed 's,//.*,,' selfhost/native/znc.zag | \
    grep -En '(^|[^[:alnum:]_])lower_program([_[:alnum:]]*)?[[:space:]]*\(' || true)
if [ -n "$direct_lower_calls" ]; then
    echo "public production driver bypasses ZIR authority" >&2
    printf '%s\n' "$direct_lower_calls" >&2
    exit 1
fi

env ZNC="$compiler" bash tests/run_zagscript_views.sh

case "$(uname -s):$(uname -m)" in
    Linux:x86_64)
        env ZNC="$compiler" bash tests/run_zir_authority.sh
        ;;
    Darwin:arm64)
        ;;
    *)
        echo "unsupported ZIR authority host" >&2
        exit 1
        ;;
esac

echo 'portable typed ZIR authority: PASS'
