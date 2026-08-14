#!/usr/bin/env bash
# Strict evidence check for a generated pure-Zag Linux kernel object.
#
# This script never manufactures a module or treats an executable as one.  A
# row is evidence-bearing only when the object is an ET_REL file with kernel
# metadata, symbol/data/text relocations, architecture-appropriate relocation
# families, and retained DWARF information.
set -eu
cd "$(dirname "$0")/.."

object=${ZAG_DRIVER_MODULE:-}
target=${ZAG_DRIVER_MODULE_TARGET:-}
series=${ZAG_DRIVER_MODULE_KERNEL_SERIES:-}
if [ -z "$object" ] || [ ! -f "$object" ]; then
  echo 'driver kernel object: BLOCKED — ZAG_DRIVER_MODULE must name an existing object'
  exit 1
fi
if ! command -v readelf >/dev/null 2>&1; then
  echo 'driver kernel object: BLOCKED — readelf is required for ELF evidence'
  exit 1
fi

header=$(readelf -h "$object")
sections=$(readelf -SW "$object")
relocs=$(readelf -Wr "$object")

if ! printf '%s\n' "$header" | rg -q 'Type:.*(REL|Relocatable file)'; then
  echo 'driver kernel object: BLOCKED — object is not ET_REL'
  exit 1
fi
if ! printf '%s\n' "$sections" | rg -q '\] \.text '; then
  echo 'driver kernel object: BLOCKED — missing .text section'
  exit 1
fi
if ! printf '%s\n' "$sections" | rg -q '\] \.data '; then
  echo 'driver kernel object: BLOCKED — missing .data section'
  exit 1
fi
for section in .modinfo .symtab .strtab; do
  if ! printf '%s\n' "$sections" | rg -q "\] ${section} "; then
    echo "driver kernel object: BLOCKED — missing ${section} section"
    exit 1
  fi
done
if ! printf '%s\n' "$sections" | rg -q '\] \.debug_(info|line) '; then
  echo 'driver kernel object: BLOCKED — retained DWARF debug sections are required'
  exit 1
fi
if [ -n "$series" ]; then
  modinfo=$(readelf -p .modinfo "$object")
  case "$series" in
    6_1|6.1|61) series_tag='zag_kernel_series=6.1' ;;
    6_6|6.6|66) series_tag='zag_kernel_series=6.6' ;;
    *) echo "driver kernel object: BLOCKED — unsupported Linux series metadata: $series"; exit 1 ;;
  esac
  if ! printf '%s\n' "$modinfo" | rg -q "$series_tag"; then
    echo "driver kernel object: BLOCKED — .modinfo lacks the explicit Zag Linux $series provenance tag"
    exit 1
  fi
  case "$target" in
    x86_64|x86-64) target_tag='zag_target=x86_64' ;;
    arm64|aarch64) target_tag='zag_target=arm64' ;;
    i686|x86) target_tag='zag_target=i686' ;;
    *) target_tag='' ;;
  esac
if [ -n "$target_tag" ] && ! printf '%s\n' "$modinfo" | rg -q "$target_tag"; then
  echo "driver kernel object: BLOCKED — .modinfo target tag does not match $target"
  exit 1
fi
if ! printf '%s\n' "$modinfo" | rg -q 'description=Pure-Zag Linux driver module'; then
  echo 'driver kernel object: BLOCKED — .modinfo lacks the explicit pure-Zag module description'
  exit 1
fi
fi
if ! printf '%s\n' "$sections" | rg -q '\] \.rela?\.text '; then
  echo 'driver kernel object: BLOCKED — missing text relocation section'
  exit 1
fi
if ! printf '%s\n' "$sections" | rg -q '\] \.rela?\.data '; then
  echo 'driver kernel object: BLOCKED — missing data relocation section'
  exit 1
fi

machine=$(printf '%s\n' "$header" | sed -n 's/.*Machine:[[:space:]]*//p')
case "$target:$machine" in
  x86_64:*X86-64*) family='R_X86_64_' ;;
  arm64:*AArch64*) family='R_AARCH64_' ;;
  i686:*80386*) family='R_386_' ;;
  :*X86-64*) family='R_X86_64_' ;;
  :*AArch64*) family='R_AARCH64_' ;;
  :*80386*) family='R_386_' ;;
  *)
    echo "driver kernel object: BLOCKED — unsupported or mismatched ELF machine: ${machine:-unknown}"
    exit 1
    ;;
esac
if ! printf '%s\n' "$relocs" | rg -q "$family"; then
  echo "driver kernel object: BLOCKED — relocation family ${family} is absent"
  exit 1
fi

echo "driver kernel object: PASS — ET_REL ${machine}, metadata, relocations, symbols, and DWARF verified"
