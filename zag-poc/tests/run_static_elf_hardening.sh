#!/usr/bin/env bash
set -eu
export LC_ALL=C
cd "$(dirname "$0")/.."

compiler=${ZNC:-./znc}
work=$(mktemp -d "${TMPDIR:-/tmp}/zag-static-elf-hardening.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

if ! command -v readelf >/dev/null 2>&1; then
    echo "static-elf-hardening: BLOCKED - readelf is required" >&2
    exit 1
fi

check_policy() {
    artifact=$1
    label=$2
    headers=$work/$(basename "$artifact").phdrs
    readelf -lW "$artifact" >"$headers"

    stack_count=$(awk '$1 == "GNU_STACK" { count += 1 } END { print count + 0 }' "$headers")
    if [ "$stack_count" -ne 1 ]; then
        echo "static-elf-hardening: $label expected exactly one GNU_STACK header" >&2
        sed -n '1,80p' "$headers" >&2
        exit 1
    fi
    if ! awk '$1 == "GNU_STACK" && $0 ~ /RW/ && $0 !~ /RWE/ { ok = 1 } END { exit(ok ? 0 : 1) }' "$headers"; then
        echo "static-elf-hardening: $label stack is not explicitly RW and non-executable" >&2
        sed -n '1,80p' "$headers" >&2
        exit 1
    fi
    if awk '$1 == "LOAD" && ($0 ~ /RWE/ || $0 ~ /W E/) { bad = 1 } END { exit(bad ? 0 : 1) }' "$headers"; then
        echo "static-elf-hardening: $label contains a writable executable LOAD segment" >&2
        sed -n '1,80p' "$headers" >&2
        exit 1
    fi
}

check_object_policy() {
    artifact=$1
    label=$2
    sections=$work/$(basename "$artifact").sections
    readelf -SW "$artifact" >"$sections"
    if ! awk '
        $3 == ".note.GNU-stack" {
            count += 1
            if ($4 != "PROGBITS" || $7 !~ /^0+$/ || $0 ~ /[[:space:]][A-Z]*X[A-Z]*[[:space:]]/) bad = 1
        }
        END { exit(count == 1 && bad == 0 ? 0 : 1) }
    ' "$sections"; then
        echo "static-elf-hardening: $label lacks one empty non-executable .note.GNU-stack" >&2
        sed -n '1,100p' "$sections" >&2
        exit 1
    fi
}

# The gate must certify the actual supported compiler, not merely source-level
# writer tests compiled by a stale seed. A pre-bootstrap compiler without the
# new policy header must fail here.
check_policy "$compiler" compiler-binary

"$compiler" selfhost/native/elf_test.zag -o "$work/elf-writer-test" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
check_policy "$work/elf-writer-test" direct-compiler-output
"$work/elf-writer-test" "$work/zelf_a" "$work/zelf_b" "$work/zelf_c" \
    >"$work/elf-writer.out"
grep -q '^A rc=0$' "$work/elf-writer.out"
grep -q '^B rc=0$' "$work/elf-writer.out"
grep -q '^C rc=0$' "$work/elf-writer.out"
grep -q '^done$' "$work/elf-writer.out"

check_policy "$work/zelf_a" single-load
set +e
"$work/zelf_a"
single_rc=$?
set -e
if [ "$single_rc" -ne 42 ]; then
    echo "static-elf-hardening: single-load artifact exited $single_rc, expected 42" >&2
    exit 1
fi

"$compiler" selfhost/native/elf_data_test.zag -o "$work/elf-data-writer-test" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$work/elf-data-writer-test" "$work/zed" >"$work/elf-data-writer.out"
grep -q '^rc=0$' "$work/elf-data-writer.out"
grep -q "^wrote $work/zed$" "$work/elf-data-writer.out"

check_policy "$work/zed" production-static
if [ "$("$work/zed")" != "hello from the data segment" ]; then
    echo "static-elf-hardening: production static artifact returned wrong output" >&2
    exit 1
fi

"$compiler" selfhost/native/elf_arm64_stack_test.zag -o "$work/arm64-writer-test" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$work/arm64-writer-test" "$work/arm64-static"
check_policy "$work/arm64-static" arm64-static

arm_runtime=not-run
if command -v qemu-aarch64-static >/dev/null 2>&1; then
    set +e
    qemu-aarch64-static "$work/arm64-static"
    arm_rc=$?
    set -e
    if [ "$arm_rc" -ne 42 ]; then
        echo "static-elf-hardening: ARM64 artifact exited $arm_rc, expected 42" >&2
        exit 1
    fi
    arm_runtime=qemu-pass
fi

mkdir -p "$work/objects"
printf 'name = "stackobjects"\nversion = "0"\nedition = "2027"\n' \
    >"$work/objects/zag.mod"
cp tests/fixtures/cabi_object_add.zag "$work/objects/add.zag"
cp tests/fixtures/cabi_object_import.zag "$work/objects/import.zag"
"$compiler" "$work/objects/add.zag" --emit-obj -o "$work/x86-add.o" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$compiler" "$work/objects/import.zag" --emit-obj -o "$work/x86-import.o" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$compiler" "$work/objects/add.zag" --target arm64 --emit-obj -o "$work/arm64-add.o" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$compiler" "$work/objects/import.zag" --target arm64 --emit-obj -o "$work/arm64-import.o" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
check_object_policy "$work/x86-add.o" x86-relocation-free-object
check_object_policy "$work/x86-import.o" x86-relocation-object
check_object_policy "$work/arm64-add.o" arm64-relocation-free-object
check_object_policy "$work/arm64-import.o" arm64-relocation-object

echo "static-elf-hardening x86_pass=8 arm64_pass=2 object_pass=4 arm64_runtime=$arm_runtime fail=0"
