#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. ./tests/portable.sh
native_compiler=./znc
native_daemon=./zagd
case "$(uname -s):$(uname -m)" in
    Darwin:arm64)
        native_compiler=./znc-macos-arm64
        native_daemon=./zagd-macos-arm64
        ;;
    Linux:aarch64|Linux:arm64)
        native_compiler=./znc-linux-arm64
        native_daemon=./zagd-linux-arm64
        ;;
esac
compiler=${ZNC:-$native_compiler}
daemon=${ZAGD:-$native_daemon}
test -x "$compiler"
test -x "$daemon"
case "$compiler" in /*) ;; *) compiler="$PWD/${compiler#./}" ;; esac
case "$daemon" in /*) ;; *) daemon="$PWD/${daemon#./}" ;; esac

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-script-install.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
lsp=${ZAG_LSP:-$(zag_native_lsp "$PWD")}
case "$lsp" in /*) ;; *) lsp="$PWD/${lsp#./}" ;; esac
if [ ! -x "$lsp" ]; then
    lsp="$tmp/zag-lsp"
    "$compiler" selfhost/lsp/zag-lsp.zag --no-zagd --no-analyze \
        --no-foreground-cache -o "$lsp"
fi

# Keep the public installer and the staged layout below coupled. `make -n`
# expands the real install recipe without rebuilding or writing /usr/local.
install_plan=$(make -n install)
for required in \
    /usr/local/bin/znc \
    /usr/local/bin/zagd \
    /usr/local/bin/zag-lsp \
    /usr/local/bin/zagd-user-service \
    /usr/local/bin/zagd-launchd-service \
    /usr/local/share/zag/zagd.conf.example \
    selfhost/std/process.zag \
    selfhost/std/process_platform.zag \
    selfhost/std/script_io.zag \
    selfhost/std/script_input.zag \
    selfhost/std/script_string_builder.zag \
    selfhost/std/script_list.zag \
    selfhost/std/script_string.zag \
    selfhost/std/script_path.zag \
    selfhost/std/script_format.zag \
    selfhost/std/script_interpolate.zag \
    selfhost/std/script_map.zag \
    selfhost/std/script_json.zag \
    selfhost/std/script_json_document.zag
do
    grep -Fq "$required" <<<"$install_plan"
done

prefix="$tmp/prefix"
project="$tmp/project"
mkdir -p "$prefix/bin" "$prefix/lib/zag/std" "$prefix/share/zag" "$project"
# Exercise the actual install recipe, not a manually maintained imitation.
# The exact executable prerequisites above are already built; suppress only
# their rebuild rules while retaining every production copy/install command.
make --no-print-directory -s -o bootstrap -o znc -o zagd -o zag-lsp install \
    PREFIX="$prefix" NATIVE_ZNC="$compiler" NATIVE_ZAGD="$daemon" NATIVE_LSP="$lsp"
cmp "$compiler" "$prefix/bin/znc"
cmp "$daemon" "$prefix/bin/zagd"
cmp "$lsp" "$prefix/bin/zag-lsp"
zag_assert_native_executable "$prefix/bin/znc"
zag_assert_native_executable "$prefix/bin/zagd"
zag_assert_native_executable "$prefix/bin/zag-lsp"
cmp examples/zagd.conf "$prefix/share/zag/zagd.conf.example"

cat >"$project/all-prelude.zag" <<'ZAG'
script;

let name = input("name: ");
let path = path_join("folder", "file.txt");
let base = path_basename(path);
let text = string_concat(base, name);
let builder = string_builder(128);
let _append = string_builder_append(&builder, text);
let values = list(1, 2, 3);
let _grow = append(values, 4);
let result = process_run_timeout("true", 100, 16);
let contents = read_file("not-read-during-compilation.txt");
println(length(values));
return process_result_status(result) + contents.len;
ZAG

cat >"$project/json.zag" <<'ZAG'
@import("std:json") as json
fn main() i32 {
    let parsed: json.JsonIntResult = json.json_parse_int("7");
    if (parsed.ok == 1 && parsed.value == 7) { return 0; }
    return 1;
}
ZAG

cat >"$project/hello.zag" <<'ZAG'
script;
println("installed Zag Script");
ZAG

(cd "$project" && "$prefix/bin/znc" all-prelude.zag -o all-prelude --no-zagd --no-analyze >/dev/null)
(cd "$project" && "$prefix/bin/znc" json.zag -o json --no-zagd --no-analyze >/dev/null)
(cd "$project" && "$prefix/bin/znc" hello.zag -o hello --no-zagd --no-analyze >/dev/null)
zag_assert_native_executable "$project/all-prelude"
zag_assert_native_executable "$project/json"
zag_assert_native_executable "$project/hello"
test "$("$project/hello")" = "installed Zag Script"
"$project/json"

echo "Zag Script staged install layout: pass (production recipe, native compiler/daemon/LSP, installed std)"
