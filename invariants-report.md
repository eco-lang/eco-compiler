  CRITICAL VIOLATIONS (Must Fix)

  1. Bool Representation Violation (REP_SSA_001, CGEN_012)

  Severity: CRITICAL - Affects correctness of all Bool-related codegen

  Root Cause: compiler/src/Compiler/Generate/MLIR/Types.elm:89-90
  Mono.MBool ->
      I1
  MBool incorrectly maps to I1 instead of ecoValue. Per REP_SSA_001 and CGEN_012, Bool must be !eco.value in SSA representation.

  Cascade Effects:
  - compiler/src/Compiler/Generate/MLIR/Expr.elm:210-223 - Bool literals generate i1
  - compiler/src/Compiler/Generate/MLIR/Intrinsics.elm:455-468 - Boolean intrinsics return i1
  - All downstream Bool operations incorrectly use i1 type

  Fix Required: Change MBool -> I1 to MBool -> ecoValue in Types.elm and update all Bool literal generation to produce eco.embed operations with True/False constants.

  ---
  2. CANON_001 Violation - VarDebug Home Module

  Severity: HIGH - Debug variables get wrong module name

  Location: compiler/src/Compiler/Canonicalize/Expression.elm:1397-1404, 1413-1425
  if home == ModuleName.debug then
      Can.VarDebug env.home name annotation  -- BUG: should be `home`
  else
      Can.VarForeign home name annotation    -- CORRECT

  The invariant states "VarDebug records home exactly", but the code uses env.home (current module) instead of home (Debug module).

  Fix Required: Change env.home to home in VarDebug constructor calls.

  ---
  HIGH SEVERITY VIOLATIONS

  3. FORBID_HEAP_002 - Direct HPointer Bitfield Manipulation

  Location: runtime/src/allocator/RuntimeExports.cpp:386-388
  cons->tail.ptr = value & 0xFFFFFFFFFF;
  cons->tail.constant = (value >> 40) & 0xF;
  cons->tail.padding = 0;

  Direct bitfield manipulation is forbidden. Must use runtime helpers for HPointer operations.

  4. FORBID_HEAP_001 - Address Range Checks

  Locations:
  - runtime/src/allocator/NurserySpace.cpp:604-610
  - runtime/src/allocator/MatureSpace.cpp (similar patterns)

  Address range checks used instead of constant bits for distinguishing embedded constants vs heap pointers. The invariant requires checking constant bits == 0 for heap pointers.

  5. CGEN_026 - Unboxed Bitmap Derivation

  Location: compiler/src/Compiler/Generate/MLIR/Functions.elm:638

  Uses ctorLayout.unboxedBitmap directly instead of deriving from SSA operand types as required by invariant.

  ---
  MEDIUM SEVERITY ISSUES

  6. MONO_015 - Unresolved Record Accessor Extension Variables

  Location: compiler/src/Compiler/Generate/Monomorphize/TypeSubst.elm

  Unresolved extension variables in record accessor function types can cause monomorphization crash. Needs defensive handling or earlier resolution.

  7. MONO_002 - CNumber Implicit Conversion

  Location: compiler/src/Compiler/Generate/Monomorphize/TypeSubst.elm:249-254

  CNumber→MInt implicit conversion not actively enforced; relies on caller discipline.

  8. HEAP_019 - Array Bitmap Limitation

  Location: Runtime array handling

  Array elements beyond index 63 have hard-coded "always boxed" assumption in bitmap. While documented, this creates implicit constraint.

  ---
  FULLY COMPLIANT CATEGORIES

  ✅ BFUSE_ / BFOPS_** (43 invariants) - All bytes fusion invariants fully compliant
  ✅ TYPE_* - Type inference invariants compliant
  ✅ NITPICK_* - Linting invariants compliant
  ✅ POST_* - Post-processing invariants compliant
  ✅ TOPT_* - Type optimization invariants compliant

  ---
  Summary Table
  ┌────────────────────────┬───────┬──────────────┬────────────┐
  │        Category        │ Total │  Violations  │ Compliance │
  ├────────────────────────┼───────┼──────────────┼────────────┤
  │ REP_*                  │ 12    │ 1 (critical) │ 92%        │
  ├────────────────────────┼───────┼──────────────┼────────────┤
  │ CGEN_*                 │ 50    │ 3            │ 94%        │
  ├────────────────────────┼───────┼──────────────┼────────────┤
  │ HEAP_*                 │ 19    │ 1            │ 95%        │
  ├────────────────────────┼───────┼──────────────┼────────────┤
  │ FORBID_*               │ 14    │ 3            │ 79%        │
  ├────────────────────────┼───────┼──────────────┼────────────┤
  │ MONO_*                 │ 15    │ 2            │ 87%        │
  ├────────────────────────┼───────┼──────────────┼────────────┤
  │ BFUSE/BFOPS_*          │ 43    │ 0            │ 100%       │
  ├────────────────────────┼───────┼──────────────┼────────────┤
  │ CANON_*                │ 5     │ 1            │ 80%        │
  ├────────────────────────┼───────┼──────────────┼────────────┤
  │ TYPE/NITPICK/POST/TOPT │ ~20   │ 0            │ 100%       │
  └────────────────────────┴───────┴──────────────┴────────────┘
  ---
  Recommended Fix Priority

  1. Immediate: Bool representation in Types.elm (cascades everywhere)
  2. High: CANON_001 VarDebug home module bug
  3. High: FORBID_HEAP_002 direct bitfield manipulation
  4. Medium: FORBID_HEAP_001 address range checks
  5. Medium: CGEN_026 bitmap derivation
  6. Low: MONO_* defensive improvements
  ⎿ {                                                                                                         
      "result": "Have you already performed all the steps required by the task? Is it appropriate to run tests
    a
    nd linting, and if so,\nhave you done that already? Is it appropriate to adjust non-code files like
    document
    … +4 lines (ctrl+o to expand)

● The comprehensive invariant scan is complete.

  Key findings:
  - 2 critical violations requiring immediate attention (Bool representation in Types.elm, CANON_001 VarDebug bug)
  - 3 high severity violations in FORBID_HEAP rules and CGEN_026
  - 3 medium severity issues in MONO_* invariants
  - Bytes fusion fully compliant - all 43 BFUSE/BFOPS invariants pass

  The most impactful fix would be correcting the Bool representation in compiler/src/Compiler/Generate/MLIR/Types.elm:89-90, which cascades through all Bool-related codegen.

