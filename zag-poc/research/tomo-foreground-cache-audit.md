# Foreground cache audit

**UNCOMPILED / UNEXECUTED.** Static source audit against `f8b287bad32d4f93d272c270cff772e59b858515`; no builds or tests were run. Conclusion: **No staleness defect found in the reviewed compiler-image, source/dependency, semantic-graph, CPU, vectorization, ABI and policy identities.** This is a scoped negative finding, not proof all output-affecting inputs or flags are covered. No omission or deterministic stale output is established, so no fix is proposed.

## Actual production callers and key

GitHub indexed searches miss the large production driver. `zag-poc/selfhost/native/znc.zag` imports `foreground_cache.zag` and invokes `foreground_cache_load` before lowering and `foreground_cache_store` on a miss, in macOS ARM64 and Linux x86-64 paths. Do not infer absence of production callers from code-search results.

The x86 key call is:

```zag
let cache_key:ForegroundCacheKey=fc_key_identity(compiler_identity,zag_version(),project_root,path,src,unit.modules,unit.resources,cache_semantic.graph,selected_cpu.cache_key,abi_text,policy_text);
```

The macOS helper passes `compiler_identity,zag_version(),project_root,path,src,unit.modules,unit.resources,semantic_graph,target,abi,policy` to the same function. `foreground_cache.zag` hashes version, project root, source label, target, ABI and policy, derives token identity of root source and dependencies (module tokens and resource contents), and binds the semantic graph and supplied compiler hash. Lexical changes that preserve token kind and value intentionally do not invalidate it.

**Actual compiler image:** `znc_current_compiler_image()` reads `/proc/self/exe` on non-macOS and reads `_zag_current_executable_path()` on macOS. The driver computes `compiler_identity=zagd_content_hash(compiler_bytes)` when nonempty; an unavailable image makes the cache ineligible. It is not merely a version string. The semantic identity is read from the just-published semantic manifest with bounded no-follow reading; an incomplete or nonmatching graph disables caching.

**Linux x86-64:** `selected_cpu.cache_key` identifies resolved CPU; ABI text binds pipeline, `|vectorize=` request, resolved `|lanes=` and `|dynamic=`. Policy binds profile, resolved Script runtime memory/capabilities/execution and project edition. The exact eligibility predicate:

```zag
if(compiler_available==1&&cache_semantic.valid==1&&has_flag("--no-foreground-cache")==0&&safety_checked==0&&x86_object_mode==0&&foreground_transform==0&&build_evidence.enabled==0){
```

Checked safety (including memory sanitizer), object mode, foreground transforms and evidence builds bypass this cache. The driver explicitly explains:

> Dynamic mode changes call lowering and is part of the cached-blob
> identity. Static -l/-L/zag.mod inputs are intentionally absent:
> archive selection and relocation happen fresh below, after code/data
> substitution. --debug likewise derives DWARF from the current AST
> after writing a fresh ELF, and --hot only records current blob sizes.
> Neither is allowed to make cached code/data authoritative for those
> later steps.

**macOS ARM64:** target binds baseline and effective CPU request; ABI binds hot page layout, dynamic, debug and imports; policy binds edition, checked safety, memory sanitizer, and Script/strict profile including resolved Script memory/capabilities/execution. Builds lacking a valid graph or readable compiler image, disabled cache or enabled build evidence are not eligible.

These are the inputs and bypasses traced in the driver, not an exhaustive proof about all imported lowering/optimizer implementations, hash collisions, runtime behavior, or every possible flag. An indexed search alone is insufficient for this audit. `zag-poc/tests/run_foreground_cache_integration.sh` expresses cold/warm, dependency token edit, CPU, debug/hot, corruption and disabled-cache assertions; those are test source, not observed results.

## Reproduction handoff (NOT RUN)

From a disposable clean checkout at the pinned commit with a built checkout-native compiler:

```sh
git checkout f8b287bad32d4f93d272c270cff772e59b858515
cd zag-poc
bash tests/run_foreground_cache_integration.sh
```

Capture compiler executable SHA-256, environment, stdout, stderr and exit code. In the integration script, changing dependency `return 42;` to `return 41;` is expected to miss and exit 41; warm runs and comparisons against `--no-foreground-cache` test the declared reuse boundary. This is an existing regression attempt, not a demonstrated stale-output reproducer.
