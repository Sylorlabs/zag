#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
compiler=${ZNC:-./znc}
tmp=$(mktemp -d /tmp/zag-zir-authority.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
repo=$PWD
# Keep edition discovery local to this fixture.  A host-level /tmp/zag.mod
# (possibly created by another test) must not silently move the opt-in rule
# into the v2 edition and turn a regular unsanitized source into a false red.
printf 'name = "zir-authority"\nedition = "2026"\n' >"$tmp/zag.mod"
case "$compiler" in
    /*) compiler_abs=$compiler ;;
    *) compiler_abs="$repo/${compiler#./}" ;;
esac

"$compiler" selfhost/zir_authority_test.zag -o "$tmp/zir_authority_test" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp/zir_authority_test"

# Prove backend selection, not merely IR construction: this test calls the
# route-witness entry directly, emits an ELF from ZIR operations, and confirms
# structured branches/mutable loops, source-ordered shadow initialization, and
# defined signed division/remainder execute directly; raw production i32 overflow
# and the source/policy-bound candidate both match the AST oracle; explicitly
# typed i64 and bounded f64 arithmetic/constants/calls plus the narrow
# inferred-i32 literal domain use the direct route when their source types are
# explicit, while source-local and explicitly-qualified imported canonical inferred scalar calls
# plus typed non-literal integer negation and exact typed integer XOR/AND/OR/shifts are checked
# against AST oracles as well;
# unresolved inferred calls or
# policy-sensitive contextual arithmetic remain on the checked AST bridge; exact
# panic behavior is preserved; and specialized
# numerics remain on the fallback.
"$compiler" selfhost/native/zir_native_backend_test.zag -o "$tmp/zir_native_backend_test" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
mkdir -p "$tmp/native-artifacts"
"$tmp/zir_native_backend_test" "$tmp/native-artifacts"
set +e
"$tmp/native-artifacts/native-scalar"
zir_scalar_rc=$?
"$tmp/native-artifacts/native-i64-constant"
zir_i64_constant_rc=$?
"$tmp/native-artifacts/native-inferred-i64-call"
zir_inferred_i64_call_rc=$?
"$tmp/native-artifacts/native-inferred-i64-one-arg"
zir_inferred_i64_one_arg_rc=$?
"$tmp/native-artifacts/production-wide-i64-named-function-value"
zir_named_function_value_rc=$?
"$tmp/native-artifacts/ast-wide-i64-named-function-value"
ast_named_function_value_rc=$?
"$tmp/native-artifacts/production-wide-i64-inferred-two-arg"
zir_inferred_i64_two_arg_rc=$?
"$tmp/native-artifacts/ast-wide-i64-inferred-two-arg"
ast_inferred_i64_two_arg_rc=$?
"$tmp/native-artifacts/production-direct-i32-inferred-two-arg"
zir_inferred_i32_two_arg_rc=$?
"$tmp/native-artifacts/ast-direct-i32-inferred-two-arg"
ast_inferred_i32_two_arg_rc=$?
"$tmp/native-artifacts/production-wide-i64-inferred-three-arg"
zir_inferred_i64_three_arg_rc=$?
"$tmp/native-artifacts/ast-wide-i64-inferred-three-arg"
ast_inferred_i64_three_arg_rc=$?
"$tmp/native-artifacts/production-direct-i32-inferred-three-arg"
zir_inferred_i32_three_arg_rc=$?
"$tmp/native-artifacts/ast-direct-i32-inferred-three-arg"
ast_inferred_i32_three_arg_rc=$?
"$tmp/native-artifacts/production-wide-i64-inferred-four-arg"
zir_inferred_i64_four_arg_rc=$?
"$tmp/native-artifacts/ast-wide-i64-inferred-four-arg"
ast_inferred_i64_four_arg_rc=$?
"$tmp/native-artifacts/production-direct-i32-inferred-four-arg"
zir_inferred_i32_four_arg_rc=$?
"$tmp/native-artifacts/ast-direct-i32-inferred-four-arg"
ast_inferred_i32_four_arg_rc=$?
"$tmp/native-artifacts/production-wide-i64-inferred-five-arg"
zir_inferred_i64_five_arg_rc=$?
"$tmp/native-artifacts/ast-wide-i64-inferred-five-arg"
ast_inferred_i64_five_arg_rc=$?
"$tmp/native-artifacts/production-direct-i32-inferred-five-arg"
zir_inferred_i32_five_arg_rc=$?
"$tmp/native-artifacts/ast-direct-i32-inferred-five-arg"
ast_inferred_i32_five_arg_rc=$?
"$tmp/native-artifacts/production-wide-i64-inferred-six-arg"
zir_inferred_i64_six_arg_rc=$?
"$tmp/native-artifacts/ast-wide-i64-inferred-six-arg"
ast_inferred_i64_six_arg_rc=$?
"$tmp/native-artifacts/production-direct-i32-inferred-six-arg"
zir_inferred_i32_six_arg_rc=$?
"$tmp/native-artifacts/ast-direct-i32-inferred-six-arg"
ast_inferred_i32_six_arg_rc=$?
"$tmp/native-artifacts/production-wide-i64-inferred-seven-arg"
zir_inferred_i64_seven_arg_rc=$?
"$tmp/native-artifacts/ast-wide-i64-inferred-seven-arg"
ast_inferred_i64_seven_arg_rc=$?
"$tmp/native-artifacts/production-direct-i32-inferred-seven-arg"
zir_inferred_i32_seven_arg_rc=$?
"$tmp/native-artifacts/ast-direct-i32-inferred-seven-arg"
ast_inferred_i32_seven_arg_rc=$?
"$tmp/native-artifacts/production-wide-i64-typed-negsi"
zir_typed_i64_negsi_rc=$?
"$tmp/native-artifacts/ast-wide-i64-typed-negsi"
ast_typed_i64_negsi_rc=$?
"$tmp/native-artifacts/production-direct-i32-typed-negsi"
zir_typed_i32_negsi_rc=$?
"$tmp/native-artifacts/ast-direct-i32-typed-negsi"
ast_typed_i32_negsi_rc=$?
"$tmp/native-artifacts/production-direct-i32-typed-xori"
zir_typed_i32_xori_rc=$?
"$tmp/native-artifacts/ast-direct-i32-typed-xori"
ast_typed_i32_xori_rc=$?
"$tmp/native-artifacts/production-wide-i64-typed-xori"
zir_typed_i64_xori_rc=$?
"$tmp/native-artifacts/ast-wide-i64-typed-xori"
ast_typed_i64_xori_rc=$?
"$tmp/native-artifacts/production-direct-i32-typed-andsi"
zir_typed_i32_andsi_rc=$?
"$tmp/native-artifacts/ast-direct-i32-typed-andsi"
ast_typed_i32_andsi_rc=$?
"$tmp/native-artifacts/production-wide-i64-typed-andsi"
zir_typed_i64_andsi_rc=$?
"$tmp/native-artifacts/ast-wide-i64-typed-andsi"
ast_typed_i64_andsi_rc=$?
"$tmp/native-artifacts/production-direct-i32-typed-orsi"
zir_typed_i32_orsi_rc=$?
"$tmp/native-artifacts/ast-direct-i32-typed-orsi"
ast_typed_i32_orsi_rc=$?
"$tmp/native-artifacts/production-wide-i64-typed-orsi"
zir_typed_i64_orsi_rc=$?
"$tmp/native-artifacts/ast-wide-i64-typed-orsi"
ast_typed_i64_orsi_rc=$?
"$tmp/native-artifacts/production-direct-i32-typed-shli"
zir_typed_i32_shli_rc=$?
"$tmp/native-artifacts/ast-direct-i32-typed-shli"
ast_typed_i32_shli_rc=$?
"$tmp/native-artifacts/production-wide-i64-typed-shrsi"
zir_typed_i64_shrsi_rc=$?
"$tmp/native-artifacts/ast-wide-i64-typed-shrsi"
ast_typed_i64_shrsi_rc=$?
"$tmp/native-artifacts/production-direct-i32-typed-cmpi-eq"
zir_typed_i32_cmpi_eq_rc=$?
"$tmp/native-artifacts/ast-direct-i32-typed-cmpi-eq"
ast_typed_i32_cmpi_eq_rc=$?
"$tmp/native-artifacts/production-wide-i64-typed-cmpi-ge"
zir_typed_i64_cmpi_ge_rc=$?
"$tmp/native-artifacts/ast-wide-i64-typed-cmpi-ge"
ast_typed_i64_cmpi_ge_rc=$?
"$tmp/native-artifacts/production-wide-i64-typed-cmpi-all"
zir_typed_i64_cmpi_all_rc=$?
"$tmp/native-artifacts/ast-wide-i64-typed-cmpi-all"
ast_typed_i64_cmpi_all_rc=$?
"$tmp/native-artifacts/production-direct-f64-typed-cmpf-all"
zir_typed_f64_cmpf_all_rc=$?
"$tmp/native-artifacts/ast-direct-f64-typed-cmpf-all"
ast_typed_f64_cmpf_all_rc=$?
"$tmp/native-artifacts/production-direct-f32-typed-cmpf-all"
zir_typed_f32_cmpf_all_rc=$?
"$tmp/native-artifacts/ast-direct-f32-typed-cmpf-all"
ast_typed_f32_cmpf_all_rc=$?
"$tmp/native-artifacts/production-direct-i32-invalid-shift-count"
zir_invalid_shift_count_rc=$?
"$tmp/native-artifacts/production-direct-qualified-import-i32"
zir_qualified_import_i32_rc=$?
"$tmp/native-artifacts/ast-direct-qualified-import-i32"
ast_qualified_import_i32_rc=$?
"$tmp/native-artifacts/production-direct-qualified-import-i32-nullary"
zir_qualified_import_i32_nullary_rc=$?
"$tmp/native-artifacts/ast-direct-qualified-import-i32-nullary"
ast_qualified_import_i32_nullary_rc=$?
"$tmp/native-artifacts/production-direct-qualified-import-i32-same-module-helper"
zir_qualified_import_i32_helper_rc=$?
"$tmp/native-artifacts/ast-direct-qualified-import-i32-same-module-helper"
ast_qualified_import_i32_helper_rc=$?
"$tmp/native-artifacts/production-wide-i64-qualified-import"
zir_qualified_import_i64_rc=$?
"$tmp/native-artifacts/ast-wide-i64-qualified-import"
ast_qualified_import_i64_rc=$?
"$tmp/native-artifacts/native-loop"
zir_loop_rc=$?
"$tmp/native-artifacts/raw-overflow"
zir_raw_overflow_rc=$?
"$tmp/native-artifacts/production-overflow"
zir_production_overflow_rc=$?
"$tmp/native-artifacts/source-policy-candidate-overflow"
zir_source_policy_candidate_overflow_rc=$?
"$tmp/native-artifacts/source-policy-bool-candidate"
zir_source_policy_bool_candidate_rc=$?
"$tmp/native-artifacts/ast-overflow"
ast_overflow_rc=$?
"$tmp/native-artifacts/production-wide-i64-let"
zir_i64_let_rc=$?
"$tmp/native-artifacts/ast-wide-i64-let"
ast_i64_let_rc=$?
"$tmp/native-artifacts/production-wide-i64-return"
zir_i64_return_rc=$?
"$tmp/native-artifacts/ast-wide-i64-return"
ast_i64_return_rc=$?
"$tmp/native-artifacts/production-wide-i64-param"
zir_i64_param_rc=$?
"$tmp/native-artifacts/ast-wide-i64-param"
ast_i64_param_rc=$?
"$tmp/native-artifacts/production-wide-i64-mutable"
zir_i64_mutable_rc=$?
"$tmp/native-artifacts/ast-wide-i64-mutable"
ast_i64_mutable_rc=$?
"$tmp/native-artifacts/production-wide-i64-div"
zir_i64_div_rc=$?
"$tmp/native-artifacts/ast-wide-i64-div"
ast_i64_div_rc=$?
"$tmp/native-artifacts/production-direct-i32-div-rem"
zir_i32_div_rem_rc=$?
"$tmp/native-artifacts/ast-direct-i32-div-rem"
ast_i32_div_rem_rc=$?
"$tmp/native-artifacts/production-direct-f64-arithmetic"
zir_f64_arithmetic_rc=$?
"$tmp/native-artifacts/ast-direct-f64-arithmetic"
ast_f64_arithmetic_rc=$?
"$tmp/native-artifacts/production-direct-f32-arithmetic"
zir_f32_arithmetic_rc=$?
"$tmp/native-artifacts/ast-direct-f32-arithmetic"
ast_f32_arithmetic_rc=$?
"$tmp/native-artifacts/production-direct-f64-negf"
zir_f64_negf_rc=$?
"$tmp/native-artifacts/ast-direct-f64-negf"
ast_f64_negf_rc=$?
"$tmp/native-artifacts/production-direct-f32-negf"
zir_f32_negf_rc=$?
"$tmp/native-artifacts/ast-direct-f32-negf"
ast_f32_negf_rc=$?
"$tmp/native-artifacts/production-direct-untyped-let"
zir_untyped_let_rc=$?
"$tmp/native-artifacts/ast-direct-untyped-let"
ast_untyped_let_rc=$?
"$tmp/native-artifacts/production-direct-untyped-nullary-call"
zir_untyped_nullary_call_rc=$?
"$tmp/native-artifacts/ast-direct-untyped-nullary-call"
ast_untyped_nullary_call_rc=$?
"$tmp/native-artifacts/production-direct-untyped-call"
zir_untyped_call_rc=$?
"$tmp/native-artifacts/ast-direct-untyped-call"
ast_untyped_call_rc=$?
"$tmp/native-artifacts/production-direct-source-order-shadow"
zir_source_order_shadow_rc=$?
"$tmp/native-artifacts/ast-direct-source-order-shadow"
ast_source_order_shadow_rc=$?
"$tmp/native-artifacts/production-direct-if-branch-local"
zir_if_branch_local_rc=$?
"$tmp/native-artifacts/ast-direct-if-branch-local"
ast_if_branch_local_rc=$?
"$tmp/native-artifacts/production-direct-nested-scalar-cast"
zir_nested_scalar_cast_rc=$?
"$tmp/native-artifacts/ast-direct-nested-scalar-cast"
ast_nested_scalar_cast_rc=$?
"$tmp/native-artifacts/production-direct-while-body-local"
zir_while_body_local_rc=$?
"$tmp/native-artifacts/ast-direct-while-body-local"
ast_while_body_local_rc=$?
"$tmp/native-artifacts/production-direct-switch-arm-local"
zir_switch_arm_local_rc=$?
"$tmp/native-artifacts/ast-direct-switch-arm-local"
ast_switch_arm_local_rc=$?
"$tmp/native-artifacts/production-direct-shadow-restoration"
zir_shadow_restoration_rc=$?
"$tmp/native-artifacts/ast-direct-shadow-restoration"
ast_shadow_restoration_rc=$?
"$tmp/native-artifacts/production-direct-bool-logic"
zir_bool_logic_rc=$?
"$tmp/native-artifacts/ast-direct-bool-logic"
ast_bool_logic_rc=$?
"$tmp/native-artifacts/native-div"
zir_div_rc=$?
"$tmp/native-artifacts/ast-div"
ast_div_rc=$?
zir_divzero_out=$("$tmp/native-artifacts/native-divzero" 2>&1)
zir_divzero_rc=$?
"$tmp/native-artifacts/native-void"
zir_void_rc=$?
set -e
test "$zir_scalar_rc" -eq 42
test "$zir_i64_constant_rc" -eq 7
test "$zir_inferred_i64_call_rc" -eq 42
test "$zir_inferred_i64_one_arg_rc" -eq 42
test "$zir_named_function_value_rc" -eq 42
test "$ast_named_function_value_rc" -eq 42
test "$zir_named_function_value_rc" -eq "$ast_named_function_value_rc"
test "$zir_inferred_i64_two_arg_rc" -eq 42
test "$ast_inferred_i64_two_arg_rc" -eq 42
test "$zir_inferred_i64_two_arg_rc" -eq "$ast_inferred_i64_two_arg_rc"
test "$zir_inferred_i32_two_arg_rc" -eq 42
test "$ast_inferred_i32_two_arg_rc" -eq 42
test "$zir_inferred_i32_two_arg_rc" -eq "$ast_inferred_i32_two_arg_rc"
test "$zir_inferred_i64_three_arg_rc" -eq 42
test "$ast_inferred_i64_three_arg_rc" -eq 42
test "$zir_inferred_i64_three_arg_rc" -eq "$ast_inferred_i64_three_arg_rc"
test "$zir_inferred_i32_three_arg_rc" -eq 42
test "$ast_inferred_i32_three_arg_rc" -eq 42
test "$zir_inferred_i32_three_arg_rc" -eq "$ast_inferred_i32_three_arg_rc"
test "$zir_inferred_i64_four_arg_rc" -eq 42
test "$ast_inferred_i64_four_arg_rc" -eq 42
test "$zir_inferred_i64_four_arg_rc" -eq "$ast_inferred_i64_four_arg_rc"
test "$zir_inferred_i32_four_arg_rc" -eq 42
test "$ast_inferred_i32_four_arg_rc" -eq 42
test "$zir_inferred_i32_four_arg_rc" -eq "$ast_inferred_i32_four_arg_rc"
test "$zir_inferred_i64_five_arg_rc" -eq 42
test "$ast_inferred_i64_five_arg_rc" -eq 42
test "$zir_inferred_i64_five_arg_rc" -eq "$ast_inferred_i64_five_arg_rc"
test "$zir_inferred_i32_five_arg_rc" -eq 42
test "$ast_inferred_i32_five_arg_rc" -eq 42
test "$zir_inferred_i32_five_arg_rc" -eq "$ast_inferred_i32_five_arg_rc"
test "$zir_inferred_i64_six_arg_rc" -eq 42
test "$ast_inferred_i64_six_arg_rc" -eq 42
test "$zir_inferred_i64_six_arg_rc" -eq "$ast_inferred_i64_six_arg_rc"
test "$zir_inferred_i32_six_arg_rc" -eq 42
test "$ast_inferred_i32_six_arg_rc" -eq 42
test "$zir_inferred_i32_six_arg_rc" -eq "$ast_inferred_i32_six_arg_rc"
test "$zir_inferred_i64_seven_arg_rc" -eq 42
test "$ast_inferred_i64_seven_arg_rc" -eq 42
test "$zir_inferred_i64_seven_arg_rc" -eq "$ast_inferred_i64_seven_arg_rc"
test "$zir_inferred_i32_seven_arg_rc" -eq 42
test "$ast_inferred_i32_seven_arg_rc" -eq 42
test "$zir_inferred_i32_seven_arg_rc" -eq "$ast_inferred_i32_seven_arg_rc"
test "$zir_typed_i64_negsi_rc" -eq 42
test "$ast_typed_i64_negsi_rc" -eq 42
test "$zir_typed_i64_negsi_rc" -eq "$ast_typed_i64_negsi_rc"
test "$zir_typed_i32_negsi_rc" -eq 42
test "$ast_typed_i32_negsi_rc" -eq 42
test "$zir_typed_i32_negsi_rc" -eq "$ast_typed_i32_negsi_rc"
test "$zir_typed_i32_xori_rc" -eq 42
test "$ast_typed_i32_xori_rc" -eq 42
test "$zir_typed_i32_xori_rc" -eq "$ast_typed_i32_xori_rc"
test "$zir_typed_i64_xori_rc" -eq 42
test "$ast_typed_i64_xori_rc" -eq 42
test "$zir_typed_i64_xori_rc" -eq "$ast_typed_i64_xori_rc"
test "$zir_typed_i32_andsi_rc" -eq 21
test "$ast_typed_i32_andsi_rc" -eq 21
test "$zir_typed_i32_andsi_rc" -eq "$ast_typed_i32_andsi_rc"
test "$zir_typed_i64_andsi_rc" -eq 21
test "$ast_typed_i64_andsi_rc" -eq 21
test "$zir_typed_i64_andsi_rc" -eq "$ast_typed_i64_andsi_rc"
test "$zir_typed_i32_orsi_rc" -eq 19
test "$ast_typed_i32_orsi_rc" -eq 19
test "$zir_typed_i32_orsi_rc" -eq "$ast_typed_i32_orsi_rc"
test "$zir_typed_i64_orsi_rc" -eq 19
test "$ast_typed_i64_orsi_rc" -eq 19
test "$zir_typed_i64_orsi_rc" -eq "$ast_typed_i64_orsi_rc"
test "$zir_typed_i32_shli_rc" -eq 48
test "$ast_typed_i32_shli_rc" -eq 48
test "$zir_typed_i32_shli_rc" -eq "$ast_typed_i32_shli_rc"
test "$zir_typed_i64_shrsi_rc" -eq 16
test "$ast_typed_i64_shrsi_rc" -eq 16
test "$zir_typed_i64_shrsi_rc" -eq "$ast_typed_i64_shrsi_rc"
test "$zir_typed_i32_cmpi_eq_rc" -eq 1
test "$ast_typed_i32_cmpi_eq_rc" -eq 1
test "$zir_typed_i32_cmpi_eq_rc" -eq "$ast_typed_i32_cmpi_eq_rc"
test "$zir_typed_i64_cmpi_ge_rc" -eq 1
test "$ast_typed_i64_cmpi_ge_rc" -eq 1
test "$zir_typed_i64_cmpi_ge_rc" -eq "$ast_typed_i64_cmpi_ge_rc"
test "$zir_typed_i64_cmpi_all_rc" -eq 1
test "$ast_typed_i64_cmpi_all_rc" -eq 1
test "$zir_typed_i64_cmpi_all_rc" -eq "$ast_typed_i64_cmpi_all_rc"
test "$zir_typed_f64_cmpf_all_rc" -eq 42
test "$ast_typed_f64_cmpf_all_rc" -eq 42
test "$zir_typed_f64_cmpf_all_rc" -eq "$ast_typed_f64_cmpf_all_rc"
test "$zir_typed_f32_cmpf_all_rc" -eq 42
test "$ast_typed_f32_cmpf_all_rc" -eq 42
test "$zir_typed_f32_cmpf_all_rc" -eq "$ast_typed_f32_cmpf_all_rc"
test "$zir_invalid_shift_count_rc" -eq 134
test "$zir_qualified_import_i32_rc" -eq 42
test "$ast_qualified_import_i32_rc" -eq 42
test "$zir_qualified_import_i32_rc" -eq "$ast_qualified_import_i32_rc"
test "$zir_qualified_import_i32_nullary_rc" -eq 42
test "$ast_qualified_import_i32_nullary_rc" -eq 42
test "$zir_qualified_import_i32_nullary_rc" -eq "$ast_qualified_import_i32_nullary_rc"
test "$zir_qualified_import_i32_helper_rc" -eq 42
test "$ast_qualified_import_i32_helper_rc" -eq 42
test "$zir_qualified_import_i32_helper_rc" -eq "$ast_qualified_import_i32_helper_rc"
test "$zir_qualified_import_i64_rc" -eq 42
test "$ast_qualified_import_i64_rc" -eq 42
test "$zir_qualified_import_i64_rc" -eq "$ast_qualified_import_i64_rc"
test "$zir_loop_rc" -eq 10
test "$zir_raw_overflow_rc" -eq 42
test "$zir_production_overflow_rc" -eq 42
test "$zir_source_policy_candidate_overflow_rc" -eq 42
test "$zir_source_policy_bool_candidate_rc" -eq 42
test "$ast_overflow_rc" -eq 42
test "$zir_raw_overflow_rc" -eq "$zir_production_overflow_rc"
test "$zir_source_policy_candidate_overflow_rc" -eq "$zir_production_overflow_rc"
test "$ast_overflow_rc" -eq "$zir_production_overflow_rc"
test "$zir_i64_let_rc" -eq 42
test "$ast_i64_let_rc" -eq "$zir_i64_let_rc"
test "$zir_i64_return_rc" -eq 42
test "$ast_i64_return_rc" -eq "$zir_i64_return_rc"
test "$zir_i64_param_rc" -eq 42
test "$ast_i64_param_rc" -eq "$zir_i64_param_rc"
test "$zir_i64_mutable_rc" -eq 42
test "$ast_i64_mutable_rc" -eq "$zir_i64_mutable_rc"
test "$zir_i64_div_rc" -eq 42
test "$ast_i64_div_rc" -eq "$zir_i64_div_rc"
test "$zir_i32_div_rem_rc" -eq 42
test "$ast_i32_div_rem_rc" -eq "$zir_i32_div_rem_rc"
test "$zir_f64_arithmetic_rc" -eq 42
test "$ast_f64_arithmetic_rc" -eq 42
test "$ast_f64_arithmetic_rc" -eq "$zir_f64_arithmetic_rc"
test "$zir_f32_arithmetic_rc" -eq 42
test "$ast_f32_arithmetic_rc" -eq 42
test "$ast_f32_arithmetic_rc" -eq "$zir_f32_arithmetic_rc"
test "$zir_f64_negf_rc" -eq 42
test "$ast_f64_negf_rc" -eq 42
test "$zir_f64_negf_rc" -eq "$ast_f64_negf_rc"
test "$zir_f32_negf_rc" -eq 42
test "$ast_f32_negf_rc" -eq 42
test "$zir_f32_negf_rc" -eq "$ast_f32_negf_rc"
test "$zir_untyped_let_rc" -eq 42
test "$ast_untyped_let_rc" -eq "$zir_untyped_let_rc"
test "$zir_untyped_nullary_call_rc" -eq 42
test "$ast_untyped_nullary_call_rc" -eq "$zir_untyped_nullary_call_rc"
test "$zir_untyped_call_rc" -eq 42
test "$ast_untyped_call_rc" -eq "$zir_untyped_call_rc"
test "$zir_source_order_shadow_rc" -eq 42
test "$ast_source_order_shadow_rc" -eq "$zir_source_order_shadow_rc"
test "$zir_if_branch_local_rc" -eq 42
test "$ast_if_branch_local_rc" -eq "$zir_if_branch_local_rc"
test "$zir_nested_scalar_cast_rc" -eq 42
test "$ast_nested_scalar_cast_rc" -eq 42
test "$zir_nested_scalar_cast_rc" -eq "$ast_nested_scalar_cast_rc"
test "$zir_while_body_local_rc" -eq 42
test "$ast_while_body_local_rc" -eq "$zir_while_body_local_rc"
test "$zir_switch_arm_local_rc" -eq 42
test "$ast_switch_arm_local_rc" -eq "$zir_switch_arm_local_rc"
test "$zir_shadow_restoration_rc" -eq 42
test "$ast_shadow_restoration_rc" -eq "$zir_shadow_restoration_rc"
test "$zir_bool_logic_rc" -eq 42
test "$ast_bool_logic_rc" -eq 42
test "$zir_bool_logic_rc" -eq "$ast_bool_logic_rc"
test "$zir_div_rc" -eq 62
test "$ast_div_rc" -eq "$zir_div_rc"
test "$zir_divzero_rc" -eq 134
test "$zir_void_rc" -eq 44
test "$zir_divzero_out" = "panic: division by zero"

# Exercise the same arithmetic family through the public foreground driver.
# The internal witness above proves route=1; this fixture proves the installed
# driver carries the selected ZIR instructions through ELF emission unchanged.
"$compiler" tests/zir_division.zag -o "$tmp/zir_division" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
set +e
"$tmp/zir_division"
zir_driver_div_rc=$?
set -e
test "$zir_driver_div_rc" -eq 62

# The bounded source/policy rule is an explicit foreground opt-in.  The
# default driver remains raw/no-transform; the opt-in must select exactly one
# checked candidate, bypass the machine-code cache, and fail closed in checked
# or non-matching domains before publishing an artifact.
cat >"$tmp/optin-add.zag" <<'ZAG'
fn main() i32 { let x:i32=2147483647+1; if (x<0) { return 42; } else { return 1; } }
ZAG
"$compiler" "$tmp/optin-add.zag" -o "$tmp/optin-default" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
set +e
"$tmp/optin-default"
optin_default_rc=$?
set -e
test "$optin_default_rc" -eq 42
"$compiler" "$tmp/optin-add.zag" -o "$tmp/optin-selected" \
    --foreground-transform const-i32-add-v1 --no-zagd --no-analyze >"$tmp/optin-selected.out"
set +e
"$tmp/optin-selected"
optin_selected_rc=$?
set -e
test "$optin_selected_rc" -eq 42
"$compiler" view "$tmp/optin-add.zag" --level native \
    --foreground-transform const-i32-add-v1 --no-zagd >"$tmp/optin-view.out"
grep -q 'semantic-transform-status=foreground_source_policy_checked' "$tmp/optin-view.out"
grep -q 'rule=const-i32-add-v1' "$tmp/optin-view.out"
grep -q 'transform_count=1' "$tmp/optin-view.out"
grep -q 'artifact_transform_consumed=1' "$tmp/optin-view.out"
set +e
"$compiler" view "$tmp/optin-add.zag" --level simple \
    --foreground-transform const-i32-add-v1 --no-zagd >"$tmp/optin-simple.out" 2>&1
optin_simple_rc=$?
"$compiler" check "$tmp/optin-add.zag" \
    --foreground-transform const-i32-add-v1 --no-zagd >"$tmp/optin-check.out" 2>&1
optin_check_rc=$?
set -e
test "$optin_simple_rc" -ne 0
test "$optin_check_rc" -ne 0
grep -q 'foreground-transform is supported only with --level native' "$tmp/optin-simple.out"
grep -q 'foreground-transform is a build/view option, not a check option' "$tmp/optin-check.out"
set +e
printf 'name = "zir-authority"\nedition = "2027"\n' >"$tmp/zag.mod"
"$compiler" "$tmp/optin-add.zag" -o "$tmp/optin-checked" \
    --foreground-transform const-i32-add-v1 --safety=checked \
    --no-zagd --no-analyze >"$tmp/optin-checked.out" 2>&1
optin_checked_rc=$?
set -e
printf 'name = "zir-authority"\nedition = "2026"\n' >"$tmp/zag.mod"
test "$optin_checked_rc" -ne 0
test ! -e "$tmp/optin-checked"
grep -q 'requires regular unsanitized x86-64 Zag' "$tmp/optin-checked.out"
cat >"$tmp/optin-no-match.zag" <<'ZAG'
fn main() i32 { let x:i32=1; return x; }
ZAG
set +e
"$compiler" "$tmp/optin-no-match.zag" -o "$tmp/optin-no-match" \
    --foreground-transform const-i32-add-v1 --no-zagd --no-analyze \
    >"$tmp/optin-no-match.out" 2>&1
optin_no_match_rc=$?
set -e
test "$optin_no_match_rc" -ne 0
test ! -e "$tmp/optin-no-match"
grep -q 'had no checked source match' "$tmp/optin-no-match.out"

# The second bounded source-policy rule is explicitly typed i64 and refuses
# overflow rather than silently changing i64 wrapping/error semantics.
cat >"$tmp/optin-i64-add.zag" <<'ZAG'
fn main() i64 { let x:i64=1+2; return x; }
ZAG
"$compiler" "$tmp/optin-i64-add.zag" -o "$tmp/optin-i64-selected" \
    --foreground-transform const-i64-add-v1 --no-zagd --no-analyze \
    --no-foreground-cache >"$tmp/optin-i64-selected.out"
set +e
"$tmp/optin-i64-selected"
optin_i64_selected_rc=$?
set -e
test "$optin_i64_selected_rc" -eq 3
"$compiler" view "$tmp/optin-i64-add.zag" --level native \
    --foreground-transform const-i64-add-v1 --no-zagd >"$tmp/optin-i64-view.out"
grep -q 'semantic-transform-status=foreground_i64_source_policy_checked' "$tmp/optin-i64-view.out"
grep -q 'rule=const-i64-add-v1' "$tmp/optin-i64-view.out"
grep -q 'transform_count=1' "$tmp/optin-i64-view.out"
grep -q 'artifact_transform_consumed=1' "$tmp/optin-i64-view.out"
cat >"$tmp/optin-i64-large.zag" <<'ZAG'
fn main() i64 { let x:i64=4611686018427387904+1; return x; }
ZAG
set +e
"$compiler" "$tmp/optin-i64-large.zag" -o "$tmp/optin-i64-large" \
    --foreground-transform const-i64-add-v1 --no-zagd --no-analyze \
    --no-foreground-cache >"$tmp/optin-i64-large.out" 2>&1
optin_i64_large_rc=$?
set -e
test "$optin_i64_large_rc" -ne 0
test ! -e "$tmp/optin-i64-large"
grep -q 'had no checked source match' "$tmp/optin-i64-large.out"

# Every public production route in znc must enter native lowering through the
# verified IR contract.  Strip line comments first so the import annotation is
# not mistaken for a call, then reject every direct lower_program* spelling.
grep -q 'lower_zir_program_mode_cpu(zir_authority' selfhost/native/znc.zag
grep -q 'lower_zir_program_mode_cpu(hot_zir_authority' selfhost/native/znc.zag
direct_lower_calls=$(sed 's,//.*,,' selfhost/native/znc.zag | \
    grep -En '(^|[^[:alnum:]_])lower_program([_[:alnum:]]*)?[[:space:]]*\(' || true)
if [ -n "$direct_lower_calls" ]; then
    echo "public production driver still bypasses Zag IR authority:" >&2
    printf '%s\n' "$direct_lower_calls" >&2
    exit 1
fi

# The broad zopt prototype still drops metadata and is not trap/width checked.
# Its focused unit remains useful, but it must not enter foreground authority.
grep -q 'experimental, test-only ZIR rewrite prototype' selfhost/native/zopt.zag
if grep -Eq '@import\("([^"/]*/)*zopt\.zag"\)' selfhost/native/znc.zag; then
    echo "test-only zopt prototype was imported by the foreground driver" >&2
    exit 1
fi
fold_callers=$(rg -n 'fold_module[[:space:]]*\(' selfhost --glob '*.zag' | \
    grep -v 'fn fold_module' || true)
if [ -n "$fold_callers" ]; then
    echo "experimental broad ZIR fold escaped test-only isolation:" >&2
    printf '%s\n' "$fold_callers" >&2
    exit 1
fi
checker_uses_producer=$(sed -n '/^fn ztc_parse_i32/,/^fn zir_authority_selected/p' \
    selfhost/zir.zag | grep -n 'ztp_' || true)
if [ -n "$checker_uses_producer" ]; then
    echo "const-i32-add checker called producer-side rule code:" >&2
    printf '%s\n' "$checker_uses_producer" >&2
    exit 1
fi
grep -q 'fn zir_propose_const_bool_cmp' selfhost/zir.zag
grep -q 'fn zir_check_const_bool_cmp_source_policy' selfhost/zir.zag
grep -q 'zir_transform_rule_const_bool_cmp' selfhost/zir_contract.zag
grep -q 'bounded bool equality certificate binds source policy and result' \
    selfhost/zir_authority_test.zag
production_uses_producer=$(sed -n \
    '/^fn zir_prepare_production_with_origins/,/^}/p' selfhost/zir.zag | \
    grep -n 'zir_propose_' || true)
if [ -n "$production_uses_producer" ]; then
    echo "production ZIR preparation enabled a test-only transform producer:" >&2
    printf '%s\n' "$production_uses_producer" >&2
    exit 1
fi

# Exercise hot-patch in an isolated work directory: its three layout files are
# intentionally cwd-scoped and must never touch the tracked hot-reload fixture.
mkdir -p "$tmp/hot-positive" "$tmp/hot-negative" "$tmp/hot-malformed"
(
    cd "$tmp/hot-positive"
    "$compiler_abs" "$repo/tests/i686_literal.zag" -o baseline --hot \
        --no-zagd --no-analyze --no-foreground-cache >/dev/null
    "$compiler_abs" hot-patch "$repo/tests/i686_literal.zag" \
        --no-zagd --no-analyze --no-foreground-cache >hot-patch.out
    test -s .zag_hotpatch
    test "$(wc -c < .zag_hotpatch)" -eq "$(cat .zag_hotlen)"
    grep -q 'znc hot-patch: staged ' hot-patch.out
)
printf '%s\n' 'fn main() MissingHotPatchType { return 0; }' \
    >"$tmp/hot-negative/unknown-type.zag"
set +e
(
    cd "$tmp/hot-negative"
    "$compiler_abs" hot-patch unknown-type.zag \
        --no-zagd --no-analyze --no-foreground-cache
) >"$tmp/hot-negative/unknown-type.out" 2>&1
hot_bad_rc=$?
set -e
test "$hot_bad_rc" -ne 0
test ! -e "$tmp/hot-negative/.zag_hotpatch"
grep -q "unknown type 'MissingHotPatchType'" \
    "$tmp/hot-negative/unknown-type.out"

set +e
(
    cd "$tmp/hot-negative"
    "$compiler_abs" hot-patch "$repo/tests/i686_literal.zag" --dynamic \
        --needed libunused.so --no-zagd --no-analyze --no-foreground-cache
) >"$tmp/hot-negative/unsupported-mode.out" 2>&1
hot_mode_rc=$?
set -e
test "$hot_mode_rc" -ne 0
grep -q 'output modes cannot be staged' "$tmp/hot-negative/unsupported-mode.out"

printf '%s\n' 'fn main() i32 { return 42; }' >"$tmp/hot-malformed/app.zag"
printf '%s\n' 'name = "hot-malformed"' >"$tmp/hot-malformed/zag.mod"
printf '%s\n' 'trust_mode=unsafe' >"$tmp/hot-malformed/.zagd.conf"
set +e
(
    cd "$tmp/hot-malformed"
    "$compiler_abs" hot-patch app.zag \
        --no-zagd --no-analyze --no-foreground-cache
) >"$tmp/hot-malformed/config.out" 2>&1
hot_config_rc=$?
set -e
test "$hot_config_rc" -ne 0
test ! -e "$tmp/hot-malformed/.zag_hotpatch"
grep -q 'znc hot-patch: invalid .zagd.conf:' "$tmp/hot-malformed/config.out"
grep -q 'trust_mode must be stable, reviewed, or autonomous' \
    "$tmp/hot-malformed/config.out"
echo "zir hot-patch foreground authority and fail-closed modes: pass"

# Exercise that bridge through the real foreground driver and prove the native
# view reports the same versioned contract instead of a separate renderer.
"$compiler" tests/i686_literal.zag -o "$tmp/scalar" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
set +e
"$tmp/scalar"
scalar_rc=$?
set -e
test "$scalar_rc" -eq 42
"$compiler" view tests/i686_literal.zag --level native --no-zagd >"$tmp/native.txt"
grep -q 'schema=zag-ir-v1 transform=zag-transform-v1 coverage_complete=1 coverage_errors=0 origin_complete=1 origin_exact=1' \
    "$tmp/native.txt"
grep -q 'zag.effects = 0' "$tmp/native.txt"
grep -q 'zag.origin = "<root>"' "$tmp/native.txt"

# A width-sensitive top-level add must remain raw in production. The bounded
# producer/checker contract is exercised only by the pure and native internal
# witnesses above until contextual types and arithmetic policy are certified.
cat >"$tmp/certified-add.zag" <<'ZAG'
fn main() i32 { let x:i32=2147483647+1; if (x<0) { return 42; } else { return 1; } }
ZAG
"$compiler" view "$tmp/certified-add.zag" --level native --no-zagd >"$tmp/certified-native.txt"
grep -q '^// native-target=linux-x86_64 cpu=.* lowering=zir-direct ir-verifier=def-before-use-v1+structured-cf-v1 artifact_ir_consumed=1$' \
    "$tmp/certified-native.txt"
grep -q '^// semantic-transform-status=verified_no_transform rule=none checker=not-run transform_count=0 artifact_transform_consumed=0$' \
    "$tmp/certified-native.txt"
grep -q 'arith.addi' "$tmp/certified-native.txt"
if grep -Eq 'formal.equivalence|equality.saturation|globally.optimal|measured.win' \
    "$tmp/certified-native.txt"; then
    echo "native view overclaimed the bounded foreground transform" >&2
    exit 1
fi

# Safety instrumentation always uses the AST bridge and may not consume an
# automatic semantic transform. The same invariant holds for sanitizer mode.
# These machine-control flags are an edition-2027 surface, so keep the
# instrumented witness in an explicit v2 project rather than accidentally
# relying on the repository's frozen edition-2026 module.
mkdir -p "$tmp/certified-v2"
cat >"$tmp/certified-v2/zag.mod" <<'MOD'
name = "zir-certified-v2"
version = "0"
edition = "2027"
MOD
cp "$tmp/certified-add.zag" "$tmp/certified-v2/certified-add.zag"
"$compiler" view "$tmp/certified-v2/certified-add.zag" --level native --no-zagd \
    --safety=checked >"$tmp/certified-native-checked.txt"
"$compiler" view "$tmp/certified-v2/certified-add.zag" --level native --no-zagd \
    --sanitize=memory >"$tmp/certified-native-sanitize.txt"
for view in "$tmp/certified-native-checked.txt" "$tmp/certified-native-sanitize.txt"; do
    grep -q '^// native-target=linux-x86_64 cpu=.* lowering=verified-ast-bridge ir-verifier=def-before-use-v1+structured-cf-v1 artifact_ir_consumed=0$' "$view"
    grep -q '^// semantic-transform-status=verified_no_transform rule=none checker=not-run transform_count=0 artifact_transform_consumed=0$' "$view"
done

# Explicit i64 declarations are preserved in raw ZIR and now use the direct
# native subset. The bounded inferred scalar domain also admits source-local
# nullary and one-argument captureless i32 calls plus nullary, one-argument,
# and two-argument captureless i32/i64 calls with canonical arguments, while
# mismatched declarations and other calls remain on the bridge. Compile and
# execute all public forms, then make both direct/bridge status combinations
# visible through the native view.
cat >"$tmp/i64-let.zag" <<'ZAG'
fn main() i32 { let wide:i64=2147483647+1; if (wide>0) { return 42; } return 1; }
ZAG
cat >"$tmp/i64-return.zag" <<'ZAG'
fn wide() i64 { return 2147483647+1; }
fn main() i32 { if (wide()>0) { return 42; } return 1; }
ZAG
cat >"$tmp/i64-param.zag" <<'ZAG'
fn accept(x:i64) i32 { if (x==2147483648) { return 42; } return 1; }
fn main() i32 { return accept(2147483647+1); }
ZAG
cat >"$tmp/i64-mutable.zag" <<'ZAG'
fn main() i32 { let wide:i64=0; wide=2147483647+1; if (wide>0) { return 42; } return 1; }
ZAG
cat >"$tmp/inferred-i64-call.zag" <<'ZAG'
fn wide() i64 { return 41; }
fn main() i64 { let answer=wide(); return answer+1; }
ZAG
cat >"$tmp/inferred-i64-one-arg.zag" <<'ZAG'
fn wide(x:i64) i64 { return x; }
fn main() i64 { let answer=wide(41); return answer+1; }
ZAG
cat >"$tmp/inferred-i64-two-arg.zag" <<'ZAG'
fn wide(a:i64,b:i64) i64 { return a+b; }
fn main() i64 { let answer=wide(40,2); return answer; }
ZAG
cat >"$tmp/inferred-i32-two-arg.zag" <<'ZAG'
fn choose(a:i32,b:i32) i32 { return a+b; }
fn main() i32 { let answer=choose(40,2); return answer; }
ZAG
cat >"$tmp/untyped-let.zag" <<'ZAG'
fn main() i32 { let answer=40+2; return answer; }
ZAG
cat >"$tmp/untyped-nullary-call.zag" <<'ZAG'
fn value() i32 { return 40; }
fn main() i32 { let answer=value(); return answer+2; }
ZAG
cat >"$tmp/untyped-call.zag" <<'ZAG'
fn value(x:i32) i32 { return x; }
fn main() i32 { let answer=value(40); return answer+2; }
ZAG
cat >"$tmp/untyped-call-mismatch.zag" <<'ZAG'
fn value(x:i64) i32 { if (x==40) { return 40; } return 0; }
fn main() i32 { let answer=value(40); return answer+2; }
ZAG

check_public_i64_direct() {
    local name=$1
    local source=$2
    "$compiler" "$source" -o "$tmp/public-$name" \
        --no-zagd --no-analyze --no-foreground-cache >/dev/null
    set +e
    "$tmp/public-$name"
    local rc=$?
    set -e
    test "$rc" -eq 42
    "$compiler" view "$source" --level native --no-zagd >"$tmp/public-$name.native"
    grep -q '^// schema=zag-ir-v1 transform=zag-transform-v1 coverage_complete=1 coverage_errors=0 origin_complete=1 origin_exact=1$' \
        "$tmp/public-$name.native"
    grep -q '^// native-target=linux-x86_64 cpu=.* lowering=zir-direct ir-verifier=def-before-use-v1+structured-cf-v1 artifact_ir_consumed=1$' \
        "$tmp/public-$name.native"
    grep -q '^// semantic-transform-status=verified_no_transform rule=none checker=not-run transform_count=0 artifact_transform_consumed=0$' \
        "$tmp/public-$name.native"
}
check_public_i64_direct i64-let "$tmp/i64-let.zag"
check_public_i64_direct i64-return "$tmp/i64-return.zag"
check_public_i64_direct i64-param "$tmp/i64-param.zag"
check_public_i64_direct i64-mutable "$tmp/i64-mutable.zag"
check_public_i64_direct inferred-i64-call "$tmp/inferred-i64-call.zag"
check_public_i64_direct inferred-i64-one-arg "$tmp/inferred-i64-one-arg.zag"
check_public_i64_direct inferred-i64-two-arg "$tmp/inferred-i64-two-arg.zag"
check_public_i64_direct inferred-i32-two-arg "$tmp/inferred-i32-two-arg.zag"

cat >"$tmp/f64-arithmetic.zag" <<'ZAG'
fn twice(x:f64) f64 { return x*2.0; }
fn main() i32 {
    let a:f64=1.5;
    let b:f64=2.25;
    let sum:f64=a+b;
    let scaled:f64=twice(sum);
    let quotient:f64=scaled/1.5;
    if (scaled==7.5) { if (quotient==5.0) { return 42; } }
    return 1;
}
ZAG
check_public_i64_direct f64-arithmetic "$tmp/f64-arithmetic.zag"

cat >"$tmp/inferred-i64-arg-mismatch.zag" <<'ZAG'
fn wide(x:i32) i64 { return 41; }
fn main() i64 { let answer=wide(41); return answer+1; }
ZAG

check_public_ast_bridge() {
    local name=$1
    local source=$2
    "$compiler" "$source" -o "$tmp/public-$name" \
        --no-zagd --no-analyze --no-foreground-cache >/dev/null
    set +e
    "$tmp/public-$name"
    local rc=$?
    set -e
    test "$rc" -eq 42
    "$compiler" view "$source" --level native --no-zagd >"$tmp/public-$name.native"
    grep -q '^// schema=zag-ir-v1 transform=zag-transform-v1 coverage_complete=0 coverage_errors=[1-9][0-9]* origin_complete=1 origin_exact=1$' \
        "$tmp/public-$name.native"
    grep -q '^// native-target=linux-x86_64 cpu=.* lowering=verified-ast-bridge ir-verifier=def-before-use-v1+structured-cf-v1 artifact_ir_consumed=0$' \
        "$tmp/public-$name.native"
    grep -q '^// semantic-transform-status=verified_raw_ast_bridge_incomplete rule=none checker=not-run transform_count=0 artifact_transform_consumed=0$' \
        "$tmp/public-$name.native"
}
check_public_i64_direct untyped-let "$tmp/untyped-let.zag"
check_public_i64_direct untyped-nullary-call "$tmp/untyped-nullary-call.zag"
check_public_i64_direct untyped-call "$tmp/untyped-call.zag"
check_public_ast_bridge untyped-call-mismatch "$tmp/untyped-call-mismatch.zag"
check_public_ast_bridge inferred-i64-arg-mismatch "$tmp/inferred-i64-arg-mismatch.zag"

# A mutable local that shadows a parameter is not visible until its initializer
# completes. The direct ZIR route and public native view must therefore read the
# outer parameter, not the zero-initialized reserved stack slot.
cat >"$tmp/source-order-shadow.zag" <<'ZAG'
fn bump(x:i32) i32 { let x:i32=x+1; x=x+1; return x; }
fn main() i32 { return bump(40); }
ZAG

# Child control-flow regions admit scalar locals that are subsequently
# assigned.  These are deliberately separate if/while/switch cases so the
# native admission proof cannot regress one region kind while retaining the
# others.  The generated native view below also proves these use the direct
# ZIR route rather than merely executing through the AST bridge.
cat >"$tmp/if-branch-mutable-local.zag" <<'ZAG'
fn main() i32 { if (1==1) { let value:i32=40; value=value+2; return value; } return 1; }
ZAG
cat >"$tmp/while-body-mutable-local.zag" <<'ZAG'
fn main() i32 { while (1==1) { let value:i32=40; value=value+2; return value; } return 1; }
ZAG
cat >"$tmp/switch-arm-mutable-local.zag" <<'ZAG'
fn main() i32 { switch (1) { 1 => { let value:i32=40; value=value+2; return value; } else => { return 1; } } return 1; }
ZAG
"$compiler" "$tmp/source-order-shadow.zag" -o "$tmp/public-source-order-shadow" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
set +e
"$tmp/public-source-order-shadow"
public_source_order_shadow_rc=$?
set -e
test "$public_source_order_shadow_rc" -eq 42
"$compiler" view "$tmp/source-order-shadow.zag" --level native --no-zagd \
    >"$tmp/public-source-order-shadow.native"
grep -q '^// schema=zag-ir-v1 transform=zag-transform-v1 coverage_complete=1 coverage_errors=0 origin_complete=1 origin_exact=1$' \
    "$tmp/public-source-order-shadow.native"
grep -q '^// native-target=linux-x86_64 cpu=.* lowering=zir-direct ir-verifier=def-before-use-v1+structured-cf-v1 artifact_ir_consumed=1$' \
    "$tmp/public-source-order-shadow.native"
grep -q '^// semantic-transform-status=verified_no_transform rule=none checker=not-run transform_count=0 artifact_transform_consumed=0$' \
    "$tmp/public-source-order-shadow.native"
check_public_i64_direct if-branch-mutable-local "$tmp/if-branch-mutable-local.zag"
check_public_i64_direct while-body-mutable-local "$tmp/while-body-mutable-local.zag"
check_public_i64_direct switch-arm-mutable-local "$tmp/switch-arm-mutable-local.zag"
echo "zir production driver, direct backend, fallback, and native view: pass"
