# New Test Cases - Round 2

Based on deep analysis of Ops.td, EcoToLLVM.cpp, and existing test coverage.

## Tests Implemented (All 25 completed)

- [x] 1. safepoint_explicit.mlir - Test eco.safepoint operation explicitly
- [x] 2. allocate_generic.mlir - Test eco.allocate (generic allocation) operation
- [x] 3. float_negative_zero.mlir - Test -0.0 vs +0.0 behavior
- [x] 4. float_subnormal.mlir - Test subnormal/denormal floating point numbers
- [x] 5. float_sqrt_edge.mlir - Test eco.float.sqrt with edge cases
- [x] 6. float_div_by_zero.mlir - Test float division by zero (returns Inf/NaN)
- [x] 7. float_to_int_overflow.mlir - Test float-to-int conversions with overflow
- [x] 8. int_div_overflow.mlir - Test integer division overflow case: INT64_MIN / -1
- [x] 9. int_negate_overflow.mlir - Test eco.int.negate with INT64_MIN
- [x] 10. int_abs_overflow.mlir - Test eco.int.abs with INT64_MIN
- [x] 11. float_minmax_nan.mlir - Test eco.float.min/max with NaN arguments
- [x] 12. int_pow_zero.mlir - Test eco.int.pow edge cases: 0^0, 1^large, large^0
- [x] 13. float_pow_edge.mlir - Test eco.float.pow edge cases
- [x] 14. expect_unboxed_passthrough.mlir - Test eco.expect with unboxed passthrough types
- [x] 15. cmp_equal_values.mlir - Test all comparison predicates with equal operands
- [x] 16. jump_multiple_args.mlir - Test eco.jump with multiple arguments
- [x] 17. case_single_branch.mlir - Test eco.case with only one alternative
- [x] 18. global_uninitialized_read.mlir - Test reading a global before any write
- [x] 19. box_unbox_extreme.mlir - Test box/unbox with extreme values
- [x] 20. string_literal_escapes.mlir - Test string literals with all escape sequences
- [x] 21. construct_scalar_bytes.mlir - Test eco.allocate_ctor with non-zero scalar_bytes
- [x] 22. project_large_index.mlir - Test eco.project with larger field indices
- [x] 23. pap_unboxed_captured.mlir - Test papCreate with unboxed captured values
- [x] 24. call_direct_void.mlir - Test eco.call with void return (no results)
- [x] 25. modby_remainderby_comprehensive.mlir - Comprehensive modBy vs remainderBy test

## Final Test Summary

All 97 codegen tests pass:
- 72 original tests
- 25 new tests from this round

Test categories covered:
- Control flow (safepoint, joinpoint/jump with multiple args, case single branch)
- Allocation (generic allocate, scalar_bytes, large project indices)
- Float edge cases (negative zero, subnormal, sqrt edge, div by zero, NaN min/max, pow edge)
- Integer edge cases (div overflow, negate overflow, abs overflow, pow zero)
- Box/unbox extremes (INT64_MIN, INT64_MAX, Inf, -0.0)
- Comparisons with equal values
- Globals (uninitialized read)
- Closures/PAP (unboxed captured, void calls)
- Modulo operations (comprehensive sign coverage)
