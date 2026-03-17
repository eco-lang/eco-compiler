  Here is the complete E2E test report.                                                                                                         
                                                                                                                                                
  E2E Test Report

  Result: 862/866 PASSED, 4 FAILED

  ---
  Failure #1, #2, #3: MLIR Parse Errors — lookupVar: unbound variable

  Failing tests:
  ┌──────────────────────────┬──────────────────┬─────────────────────────┐
  │           Test           │ Unbound Variable │       Crash Phase       │
  ├──────────────────────────┼──────────────────┼─────────────────────────┤
  │ CaseFanOutShadowTest.elm │ result           │ Generate node functions │
  ├──────────────────────────┼──────────────────┼─────────────────────────┤
  │ ClosureCapture02Test.elm │ m                │ Process lambda closures │
  ├──────────────────────────┼──────────────────┼─────────────────────────┤
  │ ClosureCapture03Test.elm │ r                │ Process lambda closures │
  └──────────────────────────┴──────────────────┴─────────────────────────┘
  Symptom: Compiler crashes with lookupVar: unbound variable <name>, producing truncated/empty MLIR that the JIT cannot parse (expected
  operation name in quotes).

  Root cause: substituteDecider and inlineVarInDecider do not substitute MonoDtPath references inside FanOut and Chain decision tree nodes.

  Trace evidence:

  1. substituteDecider at MonoInlineSimplify.elm:1306-1325 — the FanOut path and Chain testChain paths are passed through without substitution:
  Mono.FanOut path edges fallback ->
      Mono.FanOut path  -- ← DtRoot "result" NOT renamed to fresh name
  1. Compare with the existing substitutePath function (MonoInlineSimplify.elm:1286-1303) which does handle MonoRoot → but is never called from
  substituteDecider.
  2. inlineVarInDecider at MonoInlineSimplify.elm:2305-2324 — same issue:
  Mono.FanOut path edges fallback ->
      Mono.FanOut path  -- ← DtRoot not updated
  3. inlineVar on MonoCase at MonoInlineSimplify.elm:2242-2247 — the root name (second Name field) is NOT updated:
  MonoCase scrutName scrutType decider branches resultType ->
      MonoCase scrutName scrutType ...  -- scrutType = root var name, NOT renamed
  3. Compare with substitute at line 1236 which does rename it.

  Mechanism: When the inliner inlines a function call, it renames parameters to fresh names via substitute (name→name) and wraps with MonoLet.
  The MonoCase root name and leaf expressions are correctly renamed, but DtRoot nodes inside FanOut/Chain decision tree paths still reference
  the old parameter name. At MLIR gen time, Patterns.generateMonoPathHelper (Patterns.elm:337-340) calls Ctx.lookupVar ctx "result" on the stale
   name, which isn't in scope → crash.

  ---
  Failure #4: Wrong Runtime Output — EqualityStringChainCaseTest.elm

  Expected:
  case1: "matched foo+True"
  case2: "matched bar+False"
  case3: "other"

  Actual:
  case1: "other"         ← WRONG
  case2: "matched bar+False"
  case3: "other"

  Root cause: eco.project.tuple2 uses i1 result type for a Bool field stored as boxed !eco.value, violating REP_BOUNDARY_001.

  Trace evidence:

  1. The tuple is constructed with unboxed_bitmap = 0 (both fields boxed) at EqualityStringChainCaseTest.mlir:37:
  %2 = "eco.construct.tuple2"(%s, %b) {unboxed_bitmap = 0} : (!eco.value, !eco.value) -> !eco.value
  2. But the projection claims the result is i1 at line 38:
  %4 = "eco.project.tuple2"(%2) {field = 1} : (!eco.value) -> i1
  2. This reads a boxed !eco.value (an HPointer constant for True/False) and interprets the raw bits as i1, producing an incorrect boolean
  value.
  3. In the compiler, Patterns.elm:386-391 (Tuple2Container branch) passes targetType (derived from the MonoType, i1 for Bool) directly to
  ecoProjectTuple2 without checking the tuple layout's unboxed_bitmap:
  Mono.Tuple2Container ->
      Ops.ecoProjectTuple2 ctx2 resultVar index targetType subVar
  3. In contrast, the CustomContainer path at lines 400-409 explicitly calls lookupFieldIsUnboxed before choosing the projection type.
  4. Invariant violated: REP_BOUNDARY_001 states: "Projection from heap objects into SSA produces immediate MLIR operand values exactly when the
   heap layout bitmap indicates an unboxed field; otherwise projection yields !eco.value." With unboxed_bitmap = 0, field 1 is boxed, so the
  projection should return !eco.value, then a separate eco.unbox should convert to i1.
  5. Why case2 works but case1 doesn't: The outer eco.case dispatches on the projected i1. True maps to tag 1 (check "foo"), False maps to tag 0
   (check "bar"). Because the raw i1 extraction reads the wrong bit from the HPointer constant, True is misread as False, so classify "foo" True
   takes the False branch (checks "bar", fails → "other"). classify "bar" False correctly takes the False branch, matches "bar" → correct.

---

Recent work on decision tree codegen caused some ripple on test failures in the E2E test suite.

What are the fixes for these?

Would it help if DtMonoPath had used the same container hints as TypePath.Path?

type ContainerHint
    = HintList
    | HintTuple2
    | HintTuple3
    | HintCustom Name.Name -- Constructor name for layout lookup
    | HintUnknown


{-| A path describing how to access a value within a matched pattern.

  - `Index`: Access the nth field of a container with a hint about container type
  - `Unbox`: Unwrap a single-constructor custom type to access its contents
  - `Empty`: The root path (the matched value itself)

-}
type Path
    = Index Index.ZeroBased ContainerHint Path
    | Unbox Path
    | Empty


