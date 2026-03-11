# Plan: TailRec Case Crash & Kernel ABI Mismatch — Tests and Invariant Coverage

## Background

Two bugs were encountered during self-compilation:

1. **`mkCaseRegionFromDecider: non-yield terminator with empty resultVar`** — crash in `Expr.elm:3885-3889`
2. **Kernel signature mismatch on `Utils_equals`** — crash in `Context.elm:514` (`registerKernelCall`)

This plan adds E2E tests to cover these scenarios and strengthens the invariant test infrastructure to catch them earlier.

---

## Bug Analysis

### Bug 1: mkCaseRegionFromDecider crash

**Backward trace:**
1. `mkCaseRegionFromDecider` receives ExprResult with `resultVar=""` and last op != eco.yield
2. Called from `generateChainWithJumps`/`generateBoolFanOutWithJumps`/`generateFanOutGeneralWithJumps`
3. These call `generateDeciderWithJumps` -> `generateLeafWithJumps`
4. `generateLeafWithJumps` calls `generateExpr ctx branchExpr`; if `branchRes.isTerminated`, passes through directly (lines 3491, 3521)
5. `resultVar=""` is ONLY set by `generateTailCall` (Expr.elm:2830) for `MonoTailCall` nodes
6. `generateTailCall` emits `eco.jump` (a terminator, not a value-producer)

**Root cause:** A `MonoTailCall` ends up in a case branch compiled through the Expr.elm `generateCase` path instead of TailRec's `compileCaseStep`.

**Current fix status:** TailRec now handles `MonoCase`, `MonoIf`, `MonoLet`, `MonoDestruct` in `compileStep`. The defensive crash remains as a safety net. But **no E2E test validates the fix**.

**Invariants violated:**
- **CGEN_028**: Every eco.case alternative must terminate with eco.yield
- **CGEN_010**: eco.case has explicit MLIR result types; alternatives must yield matching types
- **FORBID_CF_001**: No implicit fallthrough

### Bug 2: Kernel signature mismatch on Utils_equals

**Root cause:** In `generateVarKernel` (Expr.elm:671-686), when a kernel function is referenced as a **value** (e.g., `eq = (==)`), it registers the kernel with `flattenFunctionType monoType`:

```elm
( paramTypes, resultType ) =
    Types.flattenFunctionType monoType
ctxWithKernel =
    Ctx.registerKernelCall ctx1 kernelName paramTypes resultType
```

This uses the **specialized MonoType** (e.g., `MFunction [MInt] (MFunction [MInt] MBool)` -> `(i64, i64) -> !eco.value`) without applying `kernelBackendAbiPolicy`. For `AllBoxed` kernels like `Utils.equal`, the C++ ABI is always `(!eco.value, !eco.value) -> !eco.value`.

When the same kernel is also called from:
- **Patterns.elm:885** (string comparison): `(!eco.value, !eco.value) -> !eco.value`
- **Direct call path (Expr.elm:2518-2559)**: correctly applies `AllBoxed` policy

The `generateVarKernel` path registers a CONFLICTING signature, triggering the crash.

**Invariants violated:**
- **CGEN_038**: All calls to the same kernel function name must use identical MLIR types
- **KERN_006**: Compiler is sole arbiter of kernel ABI types via `kernelBackendAbiPolicy`

---

## Part 1: E2E Test Cases

Add these test files to `test/elm/src/`.

### 1.1 TailRecCaseDestructTest.elm

Tests tail-recursive function with case expression and pattern destructuring in branches containing tail calls. Exercises `TailRec.compileCaseStep` + `compileDestructStep`.

```elm
module TailRecCaseDestructTest exposing (main)

{-| Test tail-recursive function with case expression and
pattern destructuring in branches containing tail calls.
Exercises TailRec.compileCaseStep + compileDestructStep.
-}

-- CHECK: foldl: 15
-- CHECK: sum: 10
-- CHECK: count: 3

import Html exposing (text)


myFoldl : (a -> b -> b) -> b -> List a -> b
myFoldl func acc list =
    case list of
        [] ->
            acc

        x :: xs ->
            myFoldl func (func x acc) xs


mySum : List Int -> Int
mySum list =
    myFoldl (+) 0 list


myCountHelper : Int -> List a -> Int
myCountHelper acc list =
    case list of
        [] ->
            acc

        _ :: rest ->
            myCountHelper (acc + 1) rest


main =
    let
        _ = Debug.log "foldl" (myFoldl (+) 0 [1, 2, 3, 4, 5])
        _ = Debug.log "sum" (mySum [1, 2, 3, 4])
        _ = Debug.log "count" (myCountHelper 0 [10, 20, 30])
    in
    text "done"
```

### 1.2 TailRecNestedCaseTest.elm

Tests tail-recursive function with nested case + multiple MonoTailCall paths and if-else inside case branches.

```elm
module TailRecNestedCaseTest exposing (main)

{-| Test tail-recursive function with nested case expressions
where multiple branches contain tail calls.
-}

-- CHECK: find: True
-- CHECK: nofind: False
-- CHECK: last: 4

import Html exposing (text)


contains : a -> List a -> Bool
contains target list =
    case list of
        [] ->
            False

        x :: rest ->
            if x == target then
                True
            else
                contains target rest


myLast : a -> List a -> a
myLast default list =
    case list of
        [] ->
            default

        x :: [] ->
            x

        _ :: rest ->
            myLast default rest


main =
    let
        _ = Debug.log "find" (contains 3 [1, 2, 3, 4])
        _ = Debug.log "nofind" (contains 5 [1, 2, 3, 4])
        _ = Debug.log "last" (myLast 0 [1, 2, 3, 4])
    in
    text "done"
```

### 1.3 TailRecCustomCaseTest.elm

Tests tail-recursive function with case on custom types and MonoDestruct, ensuring TailRec handles FanOut correctly.

```elm
module TailRecCustomCaseTest exposing (main)

{-| Test tail-recursive function with case on custom type and
pattern destructuring, ensuring TailRec handles FanOut correctly.
-}

-- CHECK: total: 10

import Html exposing (text)


type MyList a
    = Nil
    | Cons a (MyList a)


sumMyList : Int -> MyList Int -> Int
sumMyList acc list =
    case list of
        Nil ->
            acc

        Cons x rest ->
            sumMyList (acc + x) rest


main =
    let
        myList = Cons 1 (Cons 2 (Cons 3 (Cons 4 Nil)))
        _ = Debug.log "total" (sumMyList 0 myList)
    in
    text "done"
```

### 1.4 EqualityIntPapWithStringChainTest.elm

Tests that using `(==)` as a function value on Int coexists with string pattern matching. Exercises the kernel ABI mismatch (Bug 2).

```elm
module EqualityIntPapWithStringChainTest exposing (main)

{-| Test that using (==) as a function value on Int coexists with
string pattern matching in a case expression. Both paths register
Elm_Kernel_Utils_equal - the PAP path must use AllBoxed ABI.
Exercises CGEN_038 and KERN_006.
-}

-- CHECK: filtered: [5, 5]
-- CHECK: classify: "matched foo"

import Html exposing (text)


classify : String -> String
classify s =
    case s of
        "foo" ->
            "matched foo"

        "bar" ->
            "matched bar"

        _ ->
            "other"


main =
    let
        eq = (==)
        filtered = List.filter (eq 5) [1, 2, 5, 3, 5]
        _ = Debug.log "filtered" filtered
        _ = Debug.log "classify" (classify "foo")
    in
    text "done"
```

### 1.5 EqualityCharPapTest.elm

Tests `(==)` as PAP on Char type.

```elm
module EqualityCharPapTest exposing (main)

{-| Test that using (==) as a function value on Char works correctly.
Char uses i16 ABI, so kernel PAP must use AllBoxed (!eco.value).
-}

-- CHECK: filtered: ['a', 'a']

import Html exposing (text)


main =
    let
        eq = (==)
        filtered = List.filter (eq 'a') ['a', 'b', 'a', 'c']
        _ = Debug.log "filtered" filtered
    in
    text "done"
```

### 1.6 EqualityFloatPapTest.elm

Tests `(==)` as PAP on Float type.

```elm
module EqualityFloatPapTest exposing (main)

{-| Test that using (==) as a function value on Float works correctly.
Float uses f64 ABI, so kernel PAP must use AllBoxed (!eco.value).
-}

-- CHECK: filtered: [1.5, 1.5]

import Html exposing (text)


main =
    let
        eq = (==)
        filtered = List.filter (eq 1.5) [1.0, 1.5, 2.0, 1.5]
        _ = Debug.log "filtered" filtered
    in
    text "done"
```

### 1.7 EqualityMultiTypePapTest.elm

Tests `(==)` as PAP across multiple types in the same module — the strongest test for CGEN_038/KERN_006.

```elm
module EqualityMultiTypePapTest exposing (main)

{-| Test that (==) used as a function value across multiple types
(Int, String, Char) in the same module does not cause kernel
signature mismatch. All must use AllBoxed ABI.
-}

-- CHECK: intFiltered: [3, 3]
-- CHECK: strFiltered: ["b", "b"]
-- CHECK: classify: "matched foo"

import Html exposing (text)


classify : String -> String
classify s =
    case s of
        "foo" ->
            "matched foo"

        _ ->
            "other"


main =
    let
        eqInt = (==)
        eqStr = (==)
        intFiltered = List.filter (eqInt 3) [1, 2, 3, 4, 3]
        strFiltered = List.filter (eqStr "b") ["a", "b", "c", "b"]
        _ = Debug.log "intFiltered" intFiltered
        _ = Debug.log "strFiltered" strFiltered
        _ = Debug.log "classify" (classify "foo")
    in
    text "done"
```

---

## Part 2: Invariant Test Logic Gaps and Proposed Fixes

### 2.1 CGEN_038 (KernelAbiConsistency) — Gap Analysis

**Current state:** `KernelAbiConsistency.elm` checks that all `eco.call` ops to the same kernel name use identical types. It runs against `StandardTestSuites`.

**Gaps:**
1. **KernelCases.elm is NOT in StandardTestSuites** — kernel-specific codegen (PAP creation for kernels, intrinsics) is never exercised by CGEN_038.
2. **No SourceIR test uses `(==)` as a PAP on non-String types** — the `stringChainWithStringEquality` test in CaseCases.elm uses `==` as a binop (not PAP), and on Strings (which are already `!eco.value`).
3. **No SourceIR test combines equality PAP with string chain patterns** — this is the specific scenario that triggers the mismatch.

**Proposed fixes:**

a) **Add KernelCases to StandardTestSuites** — in `compiler/tests/SourceIR/Suite/StandardTestSuites.elm`, add `KernelCases.expectSuite expectFn condStr` to the list. This ensures all kernel-related codegen is exercised by CGEN_038, CGEN_028, BlockTerminator, etc.

b) **Add new SourceIR test cases for kernel PAP with typed specialization** — add test cases to a new `SourceIR/KernelPapAbiCases.elm` that exercise:
   - `(==)` used as a function value (PAP) on Int, then used as binop on String in the same module
   - `(==)` used as a PAP at multiple specializations (Int and String) in the same module
   - Other AllBoxed kernels (compare, append) used as PAPs with typed arguments

c) **Extend `checkKernelAbiConsistency` to also check `eco.papCreate` function references** — currently it only checks `eco.call` ops. But the signature mismatch bug originates from `registerKernelCall` called during `eco.papCreate` generation. The MLIR-level check should also scan `eco.papCreate` ops for their `function` attribute and verify the referenced kernel `func.func` declaration type matches.

### 2.2 KERN_006 (Kernel ABI Type Arbitration) — No Test Exists

**Current state:** No test logic exists for KERN_006.

**What KERN_006 requires:**
1. Kernel ABI types are computed by `kernelBackendAbiPolicy` + `monoTypeToAbi`
2. `func.func is_kernel=true` declarations carry these types
3. For AllBoxed kernels: all param types must be `!eco.value` and return type must be `!eco.value`

**Proposed new test logic:** `KernelDeclAbiPolicy.elm`

Create `compiler/tests/TestLogic/Generate/CodeGen/KernelDeclAbiPolicy.elm`:

Import `kernelBackendAbiPolicy` from `Compiler.Generate.MLIR.Context` directly (keeps test in sync with implementation).

```
Check: For every func.func with is_kernel=true:
  1. Extract the function name (strip "Elm_Kernel_" prefix, split on "_" to get home/name)
  2. Look up the expected policy via kernelBackendAbiPolicy(home, name)
  3. If policy == AllBoxed:
     - ALL parameter types must be !eco.value
     - Return type must be !eco.value
  4. Report violations with the function name, expected types, and actual types
```

This catches the bug because when `generateVarKernel` registers `Elm_Kernel_Utils_equal` with `(i64, i64) -> !eco.value`, the generated `func.func` declaration would carry those wrong types, and this test would flag that an AllBoxed kernel has non-`!eco.value` parameter types.

Create test file `compiler/tests/Compiler/Generate/CodeGen/KernelDeclAbiPolicyTest.elm` that runs the check against `StandardTestSuites` (which must include `KernelCases` per fix 2.1a).

### 2.3 CGEN_028 (CaseTermination) — Gap Analysis

**Current state:** `CaseTermination.elm` checks that every eco.case alternative terminates with `eco.yield`.

**Gaps:**
1. No SourceIR test combines tail recursion + case + destructuring — the exact pattern that caused the `mkCaseRegionFromDecider` crash would produce an `eco.jump` inside an `eco.case` alternative, which CGEN_028 would catch if the test case existed.
2. No test for `eco.caseMany` (TailRec's multi-result case) — `compileCaseChainStep` and `compileCaseFanOutStep` produce `eco.caseMany` ops. The current `CaseTermination.elm` only checks `eco.case`.

**Proposed fixes:**

a) **Add SourceIR test cases for tail-recursive functions with case+destruct** — add to `SourceIR/ClosureCases.elm` or a new `SourceIR/TailRecCaseCases.elm`:
   - Tail-recursive foldl with case on list (cons pattern with destructuring + tail call)
   - Tail-recursive function with case on custom type (FanOut with multiple constructors + tail calls)
   - Tail-recursive function with nested case (Chain within FanOut)

b) **CaseTermination.elm already covers multi-result cases** — `ecoCaseMany` emits `"eco.case"` as the op name and `ecoYieldMany` emits `"eco.yield"`. The existing check already handles both single- and multi-result cases. No code change needed to `CaseTermination.elm` — only new SourceIR test cases (2.3a) are needed.

### 2.4 CGEN_010 (eco.case Yield-Result Type Consistency) — No Test Exists

**Current state:** No test verifies that eco.yield operand types match eco.case result types.

**What CGEN_010 requires:** eco.case has explicit MLIR result types; every alternative's eco.yield must produce operands whose types match those result types (count and types).

**Proposed new test logic:** `CaseYieldResultConsistency.elm`

Create `compiler/tests/TestLogic/Generate/CodeGen/CaseYieldResultConsistency.elm`:

```
Check: For every eco.case operation:
  1. Extract result types from the eco.case op (op.results |> List.map Tuple.second)
  2. For each region (alternative):
     a. Find the terminator (must be eco.yield per CGEN_028)
     b. Extract _operand_types from the eco.yield op
     c. Compare count: len(yield operand types) must equal len(case result types)
     d. Compare types: each yield operand type must match corresponding case result type
  3. Report violations with parent eco.case ID, branch index, expected vs actual types
```

This catches both single-result and multi-result mismatches:
- For normal `ecoCase`: 1 result type must match 1 yield operand
- For `ecoCaseMany` (TailRec): N result types must match N yield operands

The MlirOp structure provides:
- `op.results : List (String, MlirType)` — eco.case result types
- `block.terminator.attrs["_operand_types"]` — eco.yield operand types (ArrayAttr of TypeAttr)
- Use `Invariants.extractOperandTypes` for the yield op and `Invariants.extractResultTypes` for the case op

Create test file `compiler/tests/Compiler/Generate/CodeGen/CaseYieldResultConsistencyTest.elm` that runs against `StandardTestSuites`.

### 2.5 CGEN_042 (BlockTerminator) — Minor Gap

**Current state:** `BlockTerminator.elm` checks valid terminators in all blocks. Would catch `eco.jump` inside an `eco.case` alternative if the test case existed.

**Gap:** Same as CGEN_028 — needs SourceIR test cases that exercise tail-recursive case paths.

**Proposed fix:** No code change needed — the SourceIR test additions from 2.3a will exercise this.

---

## Part 3: Extended Equality PAP Tests

The existing `EqualityPapWithStringChainTest.elm` only tests String equality PAPs.

### 3.1 E2E tests (from Part 1)

- **1.4** `EqualityIntPapWithStringChainTest.elm` — Int PAP + string chain
- **1.5** `EqualityCharPapTest.elm` — Char PAP
- **1.6** `EqualityFloatPapTest.elm` — Float PAP
- **1.7** `EqualityMultiTypePapTest.elm` — multiple types in same module

### 3.2 SourceIR test cases for elm-test

Add to new `SourceIR/KernelPapAbiCases.elm`:

1. **`equalityPapOnInt`** — `(==)` applied to Int, used as higher-order function argument. Verifies `Elm_Kernel_Utils_equal` PAP uses AllBoxed ABI.

2. **`equalityPapOnChar`** — `(==)` applied to Char. Char uses i16 ABI, so PAP must force to `!eco.value`.

3. **`equalityPapOnFloat`** — `(==)` applied to Float. Float uses f64 ABI.

4. **`equalityPapOnIntWithStringCase`** — `(==)` PAP on Int in the same module as a string case pattern. This is the exact mismatch trigger.

5. **`comparePapOnInt`** — `compare` used as function value on Int. Same AllBoxed policy as `equal`.

6. **`appendPapOnList`** — `(++)` used as function value on List. Same AllBoxed policy.

### 3.3 Additional types worth testing

- **Bool**: `(==)` PAP on Bool — Bool is `!eco.value` at ABI so no mismatch, but good to confirm.
- **Maybe Int**: `(==)` PAP on `Maybe Int` — composite type, always `!eco.value`.
- **Records**: `(==)` PAP on record types — always `!eco.value`.
- **Custom types**: `(==)` PAP on custom type — always `!eco.value`.

Only the **primitive unboxable types (Int/i64, Float/f64, Char/i16)** can trigger the mismatch. Bool, records, tuples, custom types, and other composite types are all `!eco.value` at ABI level and won't conflict.

---

## Implementation Order

### Phase 1: E2E tests (catches bugs at the output level)
1. Add `TailRecCaseDestructTest.elm` (1.1)
2. Add `TailRecNestedCaseTest.elm` (1.2)
3. Add `TailRecCustomCaseTest.elm` (1.3)
4. Add `EqualityIntPapWithStringChainTest.elm` (1.4)
5. Add `EqualityCharPapTest.elm` (1.5)
6. Add `EqualityFloatPapTest.elm` (1.6)
7. Add `EqualityMultiTypePapTest.elm` (1.7)
8. Run `cmake --build build --target check` to verify

### Phase 2: SourceIR test cases (catches bugs at the MLIR level)
1. Add KernelCases to StandardTestSuites (2.1a)
2. Add SourceIR test cases for kernel PAP (2.1b, 3.2)
3. Add SourceIR test cases for tail-rec case (2.3a)
4. Run `cd compiler && npx elm-test-rs --fuzz 1` to verify

### Phase 3: Invariant test logic enhancements
1. Create `KernelDeclAbiPolicy.elm` + test (2.2) — imports `kernelBackendAbiPolicy` directly
2. Create `CaseYieldResultConsistency.elm` + test (2.4) — CGEN_010 yield/result type matching
3. Extend `KernelAbiConsistency.elm` for `eco.papCreate` (2.1c)
4. Run `cd compiler && npx elm-test-rs --fuzz 1` to verify

---

## Files to Create

| File | Purpose |
|------|---------|
| `test/elm/src/TailRecCaseDestructTest.elm` | E2E: tail-rec + case + destruct |
| `test/elm/src/TailRecNestedCaseTest.elm` | E2E: tail-rec + nested case |
| `test/elm/src/TailRecCustomCaseTest.elm` | E2E: tail-rec + custom type case |
| `test/elm/src/EqualityIntPapWithStringChainTest.elm` | E2E: Int PAP + string chain |
| `test/elm/src/EqualityCharPapTest.elm` | E2E: Char PAP |
| `test/elm/src/EqualityFloatPapTest.elm` | E2E: Float PAP |
| `test/elm/src/EqualityMultiTypePapTest.elm` | E2E: multi-type PAP |
| `compiler/tests/TestLogic/Generate/CodeGen/KernelDeclAbiPolicy.elm` | KERN_006 test logic (imports `kernelBackendAbiPolicy`) |
| `compiler/tests/Compiler/Generate/CodeGen/KernelDeclAbiPolicyTest.elm` | KERN_006 test runner |
| `compiler/tests/TestLogic/Generate/CodeGen/CaseYieldResultConsistency.elm` | CGEN_010 test logic |
| `compiler/tests/Compiler/Generate/CodeGen/CaseYieldResultConsistencyTest.elm` | CGEN_010 test runner |
| `compiler/tests/SourceIR/KernelPapAbiCases.elm` | SourceIR cases for kernel PAP |
| `compiler/tests/SourceIR/TailRecCaseCases.elm` | SourceIR cases for tail-rec + case |

## Files to Modify

| File | Change |
|------|--------|
| `compiler/tests/SourceIR/Suite/StandardTestSuites.elm` | Add KernelCases, KernelPapAbiCases, TailRecCaseCases imports + calls |
| `compiler/tests/TestLogic/Generate/CodeGen/KernelAbiConsistency.elm` | Add eco.papCreate check |

---

## Decisions

1. SourceIR kernel PAP tests go in a new `KernelPapAbiCases.elm`.
2. `KernelDeclAbiPolicy` test logic imports `kernelBackendAbiPolicy` directly from `Compiler.Generate.MLIR.Context`.
3. Yes — add `CaseYieldResultConsistency.elm` for CGEN_010 (eco.yield operand types match eco.case result types). Covers both single-result and multi-result (TailRec) eco.case ops.
