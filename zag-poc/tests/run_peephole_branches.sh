#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/.."

compiler=${ZNC:-./znc}
work=$(mktemp -d "${TMPDIR:-/tmp}/zag-peephole-branch.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

"$compiler" selfhost/native/peephole_branch_test.zag -o "$work/test" \
    --no-zagd --no-analyze --no-foreground-cache >"$work/build.log" 2>&1
"$work/test" "$work"

for tool in readelf dd objdump awk; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "peephole-branch: required integration tool is missing: $tool" >&2
        exit 1
    }
done

# Source-level optimizer tests can pass while the installed compiler remains a
# stale pre-rule seed. Compile a representative program directly, isolate its
# executable LOAD bytes, and reject any jmp/jcc whose target is the next decoded
# instruction. This is the actual R6 release artifact boundary.
"$compiler" examples/numeric.zag -o "$work/numeric" \
    --no-zagd --no-analyze --no-foreground-cache >"$work/numeric.log" 2>&1
entry=$(readelf -hW "$work/numeric" | awk '/Entry point address:/ { print $4; exit }')
read -r load_off load_vaddr load_size <<EOF
$(readelf -lW "$work/numeric" | awk '$1 == "LOAD" && $0 ~ /R E/ { print $2, $3, $6; exit }')
EOF
case "$entry:$load_off:$load_vaddr:$load_size" in
    0x*:0x*:0x*:0x*) ;;
    *) echo 'peephole-branch: could not resolve direct compiler text layout' >&2; exit 1 ;;
esac
code_off=$((load_off + entry - load_vaddr))
code_size=$((load_size - (entry - load_vaddr)))
if [ "$code_size" -le 0 ]; then
    echo 'peephole-branch: direct compiler text range is empty' >&2
    exit 1
fi
dd if="$work/numeric" of="$work/numeric.text" bs=1 skip="$code_off" \
    count="$code_size" status=none
objdump -D -b binary -m i386:x86-64 --adjust-vma="$entry" \
    "$work/numeric.text" >"$work/numeric.disasm"
if ! awk '
    function norm(value) {
        sub(/^0x/, "", value); sub(/:$/, "", value); sub(/^0+/, "", value)
        return value == "" ? "0" : value
    }
    $1 ~ /^[0-9a-f]+:$/ {
        current = norm($1)
        if (pending != "" && current == pending) {
            print "adjacent branch survived before " $1 > "/dev/stderr"
            bad = 1
        }
        pending = ""
        for (i = 2; i <= NF; i++) {
            if ($i == "jmp" || $i == "je" || $i == "jne" || $i == "jl" ||
                $i == "jle" || $i == "jg" || $i == "jge") {
                pending = norm($(i + 1))
                break
            }
        }
    }
    END { exit(bad ? 1 : 0) }
' "$work/numeric.disasm"; then
    echo 'peephole-branch: supplied compiler still emits branch-to-fallthrough code' >&2
    exit 1
fi

echo "peephole-branch integration=pass direct_text_bytes=$code_size"
