# Round 4 Test Implementation Plan

## Category 1: Known Bugs / Missing Functionality
- [ ] 1. XFAIL_unbox_bool.mlir - Test eco.unbox to i1 (known crash)
- [ ] 2. float_cmp_unordered.mlir - Test float comparisons with unordered predicates for NaN
- [ ] 3. refcount_noop.mlir - Test that eco.incref/decref/free/reset are no-ops in GC mode

## Category 2: Complex Lowering Logic (Under-tested)
- [ ] 4. papextend_exact_saturation.mlir - Test papExtend where new args exactly saturate closure
- [ ] 5. papextend_chain.mlir - Chain multiple papExtend calls: f(1)(2)(3)
- [ ] 6. papextend_mixed_unboxed.mlir - papExtend with mix of boxed and unboxed new arguments
- [ ] 7. call_indirect_many_captured.mlir - Indirect call through closure with 5+ captured values
- [ ] 8. call_indirect_zero_args.mlir - Indirect call with remaining_arity=0 (thunk)
- [ ] 9. modby_all_signs.mlir - Comprehensive modBy with all sign combinations
- [ ] 10. joinpoint_mixed_arg_types.mlir - Joinpoint with i64, f64, i32, and !eco.value args

## Category 3: String Literal Edge Cases
- [ ] 11. string_literal_surrogate_pairs.mlir - Strings with emoji requiring UTF-16 surrogate pairs
- [ ] 12. string_literal_invalid_utf8.mlir - Test behavior with malformed UTF-8
- [ ] 13. string_literal_max_length.mlir - Very long string (1000+ chars)

## Category 4: Case/Pattern Matching Edge Cases
- [ ] 14. case_sparse_tags.mlir - Case with non-contiguous tags [0, 10, 100, 1000]
- [ ] 15. case_large_tag.mlir - Case with large tag values
- [ ] 16. case_in_case.mlir - Nested case expressions (case inside case branch)
- [ ] 17. case_all_jump.mlir - Every case branch jumps to same joinpoint

## Category 5: Construct/Project Edge Cases
- [ ] 18. construct_all_unboxed.mlir - Construct with all fields unboxed
- [ ] 19. construct_max_unboxed.mlir - Construct with many unboxed fields (testing bitmap)
- [ ] 20. project_unboxed_i32.mlir - Project extracting unboxed i32 (Char) field
- [ ] 21. project_after_case.mlir - Project from value after case dispatch

## Category 6: Global Variable Edge Cases
- [ ] 22. global_init_order.mlir - Multiple globals with initialization dependencies
- [ ] 23. global_store_load_cycle.mlir - Store, load, store, load pattern
- [ ] 24. global_overwrite.mlir - Overwrite global multiple times

## Category 7: Arithmetic Edge Cases Not Covered
- [ ] 25. shift_by_64.mlir - Shift left/right by exactly 64 bits
- [ ] 26. shift_by_large.mlir - Shift by amounts > 64
- [ ] 27. int_div_minint.mlir - INT64_MIN / -1 and INT64_MIN % -1
- [ ] 28. float_pow_special.mlir - pow special cases: 0^0, (-1)^inf, 1^nan

## Category 8: Allocation Edge Cases
- [ ] 29. allocate_closure_large_arity.mlir - Closure with large arity
- [ ] 30. allocate_ctor_minimal.mlir - Allocate constructor with minimal size
- [ ] 31. allocate_string_sizes.mlir - Allocate strings of various sizes

## Category 9: Debug/Crash/Expect Edge Cases
- [ ] 32. dbg_unboxed_types.mlir - eco.dbg with all unboxed types
- [ ] 33. expect_unboxed_float.mlir - eco.expect with f64 passthrough
- [ ] 34. expect_unboxed_char.mlir - eco.expect with i32 passthrough
- [ ] 35. crash_with_construct.mlir - eco.crash with constructed message

## Category 10: Control Flow Combinations
- [ ] 36. joinpoint_in_case.mlir - Joinpoint defined inside a case branch
- [ ] 37. triple_nested_joinpoint.mlir - Three levels of nested joinpoints
- [ ] 38. jump_across_case.mlir - Jump to joinpoint from inside case branch
