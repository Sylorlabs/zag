#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZNC="${ZNC:-$ROOT/znc}"
WORK="$(mktemp -d /tmp/zag-resource-affine.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

printf '%s\n' 'name = "resource-affine"' 'version = "0.0.0"' \
  'edition = "2027"' > "$WORK/zag.mod"

check_good() {
  local fixture="$1"
  cp "$ROOT/tests/resource_affine/$fixture.zag" "$WORK/$fixture.zag"
  "$ZNC" "$WORK/$fixture.zag" --no-zagd --analyze-strict \
    --no-foreground-cache -o "$WORK/$fixture"
  "$WORK/$fixture"
}

check_good positive
check_good scalar_list_positive
check_good structural_wrapper_positive

check_bad() {
  local fixture="$1"
  local needle="$2"
  cp "$ROOT/tests/resource_affine/$fixture.zag" "$WORK/$fixture.zag"
  if "$ZNC" "$WORK/$fixture.zag" --no-zagd --analyze-strict \
      --no-foreground-cache -o "$WORK/$fixture" >"$WORK/$fixture.log" 2>&1; then
    echo "resource affine negative unexpectedly compiled: $fixture" >&2
    exit 1
  fi
  if [[ -e "$WORK/$fixture" ]]; then
    echo "resource affine negative left an output artifact: $fixture" >&2
    exit 1
  fi
  if ! rg -Fq "$needle" "$WORK/$fixture.log"; then
    echo "resource affine negative missed diagnostic: $fixture" >&2
    sed -n '1,160p' "$WORK/$fixture.log" >&2
    exit 1
  fi
}

check_bad early_owner_release_bad 'resource `owner` cannot be released while a container retains a borrowed view'
check_bad retained_owner_release_bad 'resource `title` cannot be released while a container retains a borrowed view'
check_bad retained_subtitle_owner_release_bad 'resource `subtitle` cannot be released while a container retains a borrowed view'
check_bad partial_cleanup_bad 'only some control-flow paths'
check_bad double_consume_bad 'released after move, prior release, or only one control-flow path'
check_bad move_use_bad 'borrowed resource argument is unavailable after move or release'
check_bad leak_bad 'is neither released, moved, nor returned'
check_bad overwrite_live_bad 'live resource is overwritten before release or move'
check_bad move_revival_bad 'resource move source is unavailable after move or release'
check_bad post_release_read_bad 'resource read/write is unavailable after move or release'
check_bad post_release_write_bad 'resource read/write is unavailable after move or release'
check_bad pointer_alias_consume_bad 'resource pointer alias escapes exact owner tracking'
check_bad generic_concrete_wrapper_leak_bad 'resource owned by `box` is neither released, moved, nor returned'
check_bad generic_bare_t_resource_bad 'generic by-value resource argument requires an explicit ownership contract'
check_bad resource_list_push_bad 'resource-valued ArrayList element operation requires explicit move semantics'
check_bad resource_list_set_bad 'resource-valued ArrayList element operation requires explicit move semantics'
check_bad resource_list_get_bad 'resource `frames` cannot be released while a container retains a borrowed view'
check_bad resource_index_consume_bad '@consumes requires named owner arguments'
check_bad resource_list_pop_bad 'resource-valued ArrayList element operation requires explicit move semantics'
check_bad structural_sibling_release_positive 'resource read/write is unavailable after move or release'
check_bad resource_list_observation_positive '@resource struct requires at least one @owned(release) field'
check_bad moved_owner_retained_bad 'resource `moved` cannot be released while a container retains a borrowed view'
check_bad scoped_resource_leak_bad 'is neither released, moved, nor returned before its scope ends'
check_bad untracked_release_field_bad '@consumes requires named owner arguments'
check_bad untracked_consume_field_bad '@consumes requires named owner arguments'
check_bad structural_wrapper_copy_bad 'resource move source is unavailable after move or release'
check_bad structural_wrapper_double_free_bad 'resource is released after move, prior release, or only one control-flow path'
check_bad structural_wrapper_overwrite_bad 'live resource is overwritten before release or move'
check_bad nested_generic_wrapper_copy_bad 'resource move source is unavailable after move or release'
check_bad structural_observation_return_bad 'resource initialization requires a fresh producer, live move source, or retained shared view'
check_bad structural_observation_store_bad 'resource initialization requires a fresh producer, live move source, or retained shared view'

echo "resource affine contracts: PASS"
