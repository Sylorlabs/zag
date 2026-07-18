#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp_dir=$(mktemp -d /tmp/zag-x86-profile.XXXXXX)
trap 'rm -rf "$tmp_dir"' EXIT

./znc selfhost/native/x86_cpu_profile_test.zag -o "$tmp_dir/test" --no-analyze >/dev/null
"$tmp_dir/test"
