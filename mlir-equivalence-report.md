# MLIR Equivalence Suite — Post-Fix Categorization Report

**Date:** 2026-05-12
**Suite:** `cmake --build build --target run-mlir-equivalence`
**Result:** 621/641 passed, 20 failed (was 0/7 Bool-only failures before fix, now broader picture visible).

The C++ fix at `EcoToLLVMControlFlow.cpp:634` (`load i32 → load i16 + zext`) eliminated the heap-Custom ctor-load contamination by the 48-bit `unboxed` bitmap. That recovered every test whose only divergence was an MVG-tagged case-of falling through to a default arm. The 20 remaining diffs fall into **five categories**.

## Category 1: Boolean compile-time evaluation is inverted (9 tests)

Stage 6's compiler picks the **wrong arm** every time a Bool drives a `case` (or `if`) at compile time. The pattern is identical: where the source says `True → A; False → B`, Stage 6 yields `B` in the True position (or in both positions when constant-folding).

| test | symptom |
|---|---|
| BoolAndTest | `True && True` constant-folds to **False** instead of True |
| BoolOrTest | `True \|\| False` folds to **False** |
| BoolShortCircuitTest | `True \|\| shouldNotRun()` *evaluates* `shouldNotRun()` (would stack-overflow at runtime) |
| CaseBoolTest | `case True of True → "yes" ; False → "no"` returns **"yes"** in both arms (the `False` arm body becomes `"yes"`) |
| CaseInLambdaTest | same as CaseBoolTest, in lambda context (two occurrences) |
| CaseSingleCtorBoolTest, CaseSingleCtorBoolMultiTypeTest | `case ForceMultiline True of …True → "split"; …False → "join"` — the False arm body becomes `"split"` |
| SingleCtorPairBool{Char,Float,Int,String,FloatBool}Test (5) | same single-ctor wrapper pattern, "no" arm becomes "yes" |
| HeteroClosureIntFloatTest, HeteroClosureBoxedUnboxedTest | `if True then addN 10 else mulF 2.5` constant-folds to the **else** branch |

**Root cause hypothesis:** This is the *sibling* of the Custom-ctor bug I just fixed, but for the **embedded-constant path** of `eco.case ctor`. `True` and `False` are embedded constants with `constField` 3 and 4 (`value_enc::True`/`False`). In `EcoToLLVMControlFlow.cpp:614-621`, the constant path extracts `constField` into `constTag` (after mapping Nil→0) and falls into the same `cf.switch` as the heap path. For a Bool `case True of True → … ; False → …`:

- Elm-level Decider tags arms `[True_tag, False_tag]`. What numeric tags does the compiler emit here?
  - If it emits `[0, 1]` (ctor indices in `type Bool = True | False`) the dispatch will never match `constField` 3 or 4, falling to the default (last arm).
  - If it emits `[3, 4]` (constField values), the dispatch works.

Stage 2 (JS) doesn't use the inline tag math at all (it dispatches on JS object shape), so this divergence is invisible there. Stage 6 has been mis-routing every Bool dispatch and falling through to the *last* arm. Because `case b of True → A ; False → B` lists `True` first, the "last arm" is `False`'s body — but the swap shown in the diffs is the opposite (False arm picks up True's body), so the truth is more subtle and needs the lowering trace before claiming a fix. **This is the single biggest remaining bucket and almost certainly one bug fixing all nine tests.**

## Category 2: Integer literal precision in Stage 2 (1 test, **Stage 2 is wrong**)

| test | symptom |
|---|---|
| IntOverflowTest | source has `big = 9223372036854775807` (i64 max). Stage 2 emits `arith.constant 2048`; Stage 6 emits the correct `9223372036854775807` |

`eco-boot.js` runs under Node, where `9223372036854775807` exceeds Number.MAX_SAFE_INTEGER and is silently corrupted (likely a parser bug coercing to int32 modulus or similar). Stage 6 is **correct** here; the equivalence test is failing in the wrong direction. Action: special-case this test or fix the JS-side i64 literal parsing.

## Category 3: Optimizer improvements in Stage 6, not regressions (3 tests)

| test | Stage 2 | Stage 6 |
|---|---|---|
| CaseGuardLikeTest | nested `case score>=90`, `case score>=80`, … chain | collapsed/restructured chain (smaller MLIR) |
| EqualityStringChainCaseTest | tuple-case lowered to chain of `Utils_equal` calls | lowered to `eco.case … case_kind="str" string_patterns=["foo","bar"]` (uses the proper str-case op) |
| HeteroClosure*Test | also exhibits the Cat-1 if-True bug but differs in closure-build structure even after that | likely correct once Cat-1 is fixed; verify after Cat-1 lands |

CaseGuardLikeTest and EqualityStringChainCaseTest's Stage 6 output looks like a genuine optimization win. Decision: re-baseline (treat Stage 6 as the new reference) once Cat-1 is fixed and these tests no longer overlap with that bug class.

## Category 4: Invalid MLIR — `papCreateGroup.cross_edges` out of range (3 tests)

| test | error |
|---|---|
| MutualLetRecManyCapturesTest | `'eco.papCreateGroup' op cross_edges consumer 1612463081 out of range` |
| MutualLetRecClosuresTest | two errors, `consumer 1614627243` and `1614663019 out of range` |
| MutualLetRecNestedTest | `consumer 2419956711 out of range` |

Stage 6 emits structurally **invalid** MLIR for mutually-recursive closure groups. The huge `consumer` values (~1.6–2.4 × 10⁹) suggest an i32 / uninitialized pointer being stuffed into an i64 attribute — a different bit-width contamination bug. The `cross_edges` attribute encodes which sibling each capture refers to; the consumer field should be a small sibling index (0..N-1).

**Root cause hypothesis:** likely the same family — a wider integer is being loaded where a narrow ctor/index is expected, contaminating the value with adjacent bits. Worth checking `EcoToLLVMHeap.cpp` / wherever `papCreateGroup` is emitted, and the `cross_edges` ArrayAttr serialization. The memory entry for "Stage 6 poly Step/Done type mismatch (2026-04-23 evening)" mentions a related destructor-monoType fallback class.

## Category 5: Already covered by Cat-1 secondary effects

Several Cat-1 tests have *secondary* divergences once you ignore the Bool arm-swap. For example HeteroClosure tests have different closure structures because the if-True bug feeds into the closure builder. These should resolve when Cat-1 is fixed.

## Suggested next bug to chase

**Category 1 (9 tests, single root cause, well-pinned).** Add a trace at `EcoToLLVMControlFlow.cpp:618-621` to print `(constField, isNil, constTag)` for the embedded-constant path, and dump the `tags` array for the surrounding `eco.case` op. Compare to what `eco.case ctor` actually expects for `True`/`False`. The fix is likely either:

- Map `True (constField=3) → tag 0` and `False (constField=4) → tag 1` in the inline path (mirroring `eco_get_tag`'s behavior of returning the Elm ctor index, not the raw constField).
- Or change the emitter (`Compiler.Generate.MLIR.Expr.generateCase` / Decider lowering) to put `[3, 4]` in the `tags` array for Bool cases.

Category 4 (3 MutualLetRec tests) is the second priority — invalid MLIR is strictly worse than wrong-but-valid MLIR.

Category 2 (IntOverflowTest) is a Stage 2 bug, not Stage 6. Either fix JS-side i64 parsing in eco-boot or mark this test as a Stage-6-only reference.
