#!/usr/bin/env bash
# Validate the narrow Kbuild handoff for one pure-Zag kernel object.
set -eu

kbuild=${ZAG_DRIVER_KBUILD:-}
if [ -z "$kbuild" ] || [ ! -f "$kbuild" ]; then
  echo 'driver Kbuild: BLOCKED — ZAG_DRIVER_KBUILD must name an existing Kbuild file'
  exit 1
fi

if ! rg -q '^[[:space:]]*obj-m[[:space:]]*[:+?]?=' "$kbuild"; then
  echo 'driver Kbuild: BLOCKED — Kbuild must declare an obj-m final module'
  exit 1
fi

if ! rg -q '^[[:space:]]*[A-Za-z0-9_.-]+-objs[[:space:]]*[:+?]?=' "$kbuild"; then
  echo 'driver Kbuild: BLOCKED — final module must consume an explicit generated Zag payload object'
  exit 1
fi

if rg -n '\.(c|cc|cpp|S)([[:space:]]|$)' "$kbuild" >/dev/null; then
  echo 'driver Kbuild: BLOCKED — C/C++/assembly driver source is outside the pure-Zag boundary'
  exit 1
fi

if ! rg -q 'Zag|ZAG|pure[- ]Zag|generated object|kernel.*link' "$kbuild"; then
  echo 'driver Kbuild: BLOCKED — Kbuild must document the pure-Zag object handoff'
  exit 1
fi

if ! rg -q 'if_changed|ZAG_DRIVER_PREBUILT' "$kbuild"; then
  echo 'driver Kbuild: BLOCKED — generated payload handoff must use Kbuild change tracking'
  exit 1
fi

echo 'driver Kbuild: PASS — kernel-owned obj-m final-link boundary verified'
