#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
compiler=${ZNC:-./znc}
test -x "$compiler"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-script-install.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# Keep the public installer and the staged layout below coupled. `make -n`
# expands the real install recipe without rebuilding or writing /usr/local.
install_plan=$(make -n install)
for required in \
    /usr/local/bin/znc \
    /usr/local/bin/zagd \
    /usr/local/bin/zagd-user-service \
    /usr/local/bin/zagd-launchd-service \
    /usr/local/share/zag/zagd.conf.example \
    selfhost/std/process.zag \
    selfhost/std/script_io.zag \
    selfhost/std/script_input.zag \
    selfhost/std/script_string_builder.zag \
    selfhost/std/script_list.zag \
    selfhost/std/script_string.zag \
    selfhost/std/script_path.zag
do
    grep -Fq "$required" <<<"$install_plan"
done

prefix="$tmp/prefix"
project="$tmp/project"
mkdir -p "$prefix/bin" "$prefix/lib/zag/std" "$prefix/share/zag" "$project"
cp "$compiler" ./zagd "$prefix/bin/"
cp examples/zagd.conf "$prefix/share/zag/zagd.conf.example"
cmp examples/zagd.conf "$prefix/share/zag/zagd.conf.example"
cp std/*.zag "$prefix/lib/zag/std/"
cp selfhost/std/process.zag \
   selfhost/std/script_io.zag \
   selfhost/std/script_input.zag \
   selfhost/std/script_string_builder.zag \
   selfhost/std/script_list.zag \
   selfhost/std/script_string.zag \
   selfhost/std/script_path.zag \
   "$prefix/lib/zag/std/"

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
test "$("$project/hello")" = "installed Zag Script"
"$project/json"

echo "Zag Script staged install layout: pass"
