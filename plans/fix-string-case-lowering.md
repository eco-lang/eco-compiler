# Fix String Case Lowering (Option B)

## 0. Problem Statement & Design Constraints

### Current breakage (must fix both)

1. **Non-unique tags**: `DT.IsStr _ -> 0` means *every* string test becomes tag 0, breaking multi-way `eco.case` on strings.
2. **Lowering mismatch**: `eco.case` lowering for `"str"` currently has no string literals to compare against, so any lowering that relies on tags (or ADT tag extraction) cannot work.

### Hard requirements

- Multi-way string matching must be correct for:
  - `"foo" -> ...`
  - `"bar" -> ...`
  - `_ -> ...` (default)
- **No silent failure**: if a "string fanout" contains any edge test that is not `DT.IsStr`, codegen must **crash/fail loudly**.
- Empty string literal must be handled using the embedded constant (`EmptyString`) and never heap-allocated (this is already an existing invariant in test generation).

---

## 1. IR Contract: Extend `eco.case` with string literals

### 1.1 TableGen: add `string_patterns` attribute

**File:** `runtime/src/codegen/Ops.td`
**Where:** `def Eco_CaseOp` arguments list

#### Change

```tablegen
let arguments = (ins
  Eco_AnyValue:$scrutinee,
  DenseI64ArrayAttr:$tags,
  OptionalAttr<ArrayAttr>:$caseResultTypes,
  StrAttr:$case_kind,
  OptionalAttr<ArrayAttr>:$string_patterns  // NEW
);
```

#### Update the op description

Add to the description:

- For `case_kind="str"`:
  - `string_patterns` is required.
  - It contains **N-1** string literals, one per non-default alternative.
  - The **last alternative region is the default**.
  - `tags` are branch indices `[0..N-1]` (or any consistent mapping), but **lowering must ignore tags for dispatch** and use string equality chain.

#### Why

This makes `eco.case` self-contained: lowering can compare the scrutinee against literals without relying on tags (which are semantically meaningless for strings today).

---

## 2. Verifier + Parser/Printer for `eco.case`

### 2.1 Verifier: enforce string-case invariants

**File:** `runtime/src/codegen/EcoOps.cpp`
**Where:** `CaseOp::verify()`

#### Rules to enforce

1. `string_patterns` **must be present** for `case_kind == "str"`.
2. Let `numAlts = getAlternatives().size()`. Then:
   - `string_patterns.size() == numAlts - 1`
   - The last alternative is default (implicit; enforced by size rule)
3. Every element of `string_patterns` must be `StringAttr`.
4. Optional but strongly recommended: enforce `tags.size() == numAlts`
   - and that tags are exactly `[0..numAlts-1]` (helps catch bad upstream generation early).

#### Example verifier code

```cpp
if (caseKind == "str") {
  auto patternsAttr = getStringPatternsAttr();
  if (!patternsAttr) {
    return emitOpError("case_kind 'str' requires 'string_patterns' attribute");
  }

  size_t numAlts = getAlternatives().size();
  size_t numPatterns = patternsAttr.size();

  if (numPatterns + 1 != numAlts) {
    return emitOpError("string_patterns has ")
           << numPatterns << " elements but expected " << (numAlts - 1)
           << " (one per non-default alternative)";
  }

  for (Attribute a : patternsAttr) {
    if (!isa<StringAttr>(a)) {
      return emitOpError("string_patterns must contain only string attributes");
    }
  }

  // Optional extra invariant: tags must match alternative count
  auto tagsAttr = getTags();
  if (tagsAttr.size() != numAlts) {
    return emitOpError("tags has ")
           << tagsAttr.size() << " elements but expected " << numAlts
           << " (one per alternative)";
  }
}
```

#### Why

This ensures:
- the IR is well-formed,
- the lowering can rely on positional alignment between `string_patterns[i]` and alternative region `i`,
- we never "guess" what the default is.

---

### 2.2 Parser/Printer: round-trip support

**File:** `runtime/src/codegen/EcoOps.cpp`
**Where:** custom parser/printer for `eco.case`

#### Design: assembly syntax

Add an optional clause that only appears for string cases:
- **Printer** emits: `patterns = ["foo", "bar"]`
- **Parser** recognizes that clause and stores it as `string_patterns`.

#### Parser logic

After parsing `case_kind`, if `case_kind == "str"`:
- parse mandatory `patterns = <arrayattr>` (or optional in parser but required by verifier)

#### Printer logic

If `string_patterns` attribute exists, print:
- `patterns = <arrayattr>`

#### Why

Engineers can inspect MLIR text and see the actual strings that will be compared.

---

## 3. Elm MLIR Generation Changes (Fail Loudly)

This is the core "no silent failure" requirement.

### 3.1 Add a dedicated `ecoCaseString` builder

**File:** `compiler/src/Compiler/Generate/MLIR/Ops.elm`
**Where:** next to existing `ecoCase`

#### Add function

```elm
ecoCaseString :
    Ctx.Context
    -> String
    -> MlirType
    -> List Int
    -> List String
    -> List MlirRegion
    -> List MlirType
    -> ( Ctx.Context, MlirOp )
ecoCaseString ctx scrutinee scrutineeType tags stringPatterns regions resultTypes =
    let
        attrsBase =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing [ TypeAttr scrutineeType ] )
                , ( "tags", ArrayAttr (Just I64) (List.map (\t -> IntAttr Nothing t) tags) )
                , ( "case_kind", StringAttr "str" )
                , ( "string_patterns"
                  , ArrayAttr Nothing (List.map StringAttr stringPatterns)
                  )
                ]

        attrs =
            Dict.insert "caseResultTypes"
                (ArrayAttr Nothing (List.map TypeAttr resultTypes))
                attrsBase
    in
    mlirOp ctx "eco.case"
        |> opBuilder.withOperands [ scrutinee ]
        |> opBuilder.withRegions regions
        |> opBuilder.withAttrs attrs
        |> opBuilder.build
```

#### Why

The existing `ecoCase` can't attach `string_patterns`; this avoids overloading `ecoCase` with optional behavior and keeps callsites explicit.

---

### 3.2 Update `generateFanOutGeneral` to handle `"str"` with strict validation

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`
**Where:** function `generateFanOutGeneral`

#### Current bug source

`Patterns.testToTagInt` returns 0 for every `DT.IsStr`, so multi-way tags collapse.

#### Replace the tag+fallback logic for string cases

Rules for string fanout:
- `caseKind == "str"`
- all edge tests **must** be `DT.IsStr s`
- the fallback region is default `_`
- tags become purely positional: `[0, 1, ..., N-1]` where `N = number of alternatives = edges + 1 fallback`
- `string_patterns` list is length `edges` (N-1), aligned to the first `edges` regions

#### Implement strict extraction (fail loudly)

Add helper in `Expr.elm`:

```elm
extractStringPatternStrict : DT.Test -> String
extractStringPatternStrict test =
    case test of
        DT.IsStr s ->
            s

        _ ->
            Utils.Crash.crash "CGEN: expected DT.IsStr in string fanout, but got non-string test"
```

#### Modify `generateFanOutGeneral`

Replace the "collect tags from edges + compute fallback tag" path with:

```elm
-- Determine case kind from the first edge test
caseKind =
    case edgeTests of
        firstTest :: _ ->
            Patterns.caseKindFromTest firstTest
        [] ->
            "ctor"

scrutineeType =
    Patterns.scrutineeTypeFromCaseKind caseKind

( pathOps, scrutineeVar, ctx1 ) =
    Patterns.generateDTPath ctx root path scrutineeType

-- NEW: Handle string cases with strict pattern extraction
( tags, stringPatterns ) =
    if caseKind == "str" then
        let
            edgeCount = List.length edges
            altCount = edgeCount + 1  -- includes fallback/default

            patterns =
                edges
                    |> List.map Tuple.first
                    |> List.map extractStringPatternStrict

            sequentialTags =
                List.range 0 (altCount - 1)
        in
        ( sequentialTags, Just patterns )

    else
        let
            edgeTags =
                List.map (\( test, _ ) -> Patterns.testToTagInt test) edges

            fallbackTag =
                Patterns.computeFallbackTag edgeTests
        in
        ( edgeTags ++ [ fallbackTag ], Nothing )
```

Then, when building the op, switch:

```elm
( ctx3, caseOp ) =
    case stringPatterns of
        Just patterns ->
            Ops.ecoCaseString ctx2a scrutineeVar scrutineeType tags patterns allRegions [ resultTy ]

        Nothing ->
            Ops.ecoCase ctx2a scrutineeVar scrutineeType caseKind tags allRegions [ resultTy ]
```

#### Why (and why this is "fail loudly")

- We never `filterMap`; we never drop patterns.
- If a string fanout contains a non-string test, we crash immediately (compiler bug).
- Patterns list length is guaranteed to equal edge region count.

---

## 4. LLVM Lowering: implement real string dispatch in `eco.case`

### 4.1 Add a runtime declaration helper: `getOrCreateUtilsEqual`

#### 4.1.1 Header addition

**File:** `runtime/src/codegen/Passes/EcoToLLVMInternal.h`
**Where:** inside `struct EcoRuntime` methods list

Add:

```cpp
mlir::LLVM::LLVMFuncOp getOrCreateUtilsEqual(mlir::OpBuilder &builder) const;
```

#### Why

String case lowering will need to call `Elm_Kernel_Utils_equal`, which is already used by string test generation elsewhere.

---

#### 4.1.2 Implement in runtime helper module

**File:** `runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp`
**Where:** method definitions for `EcoRuntime::getOrCreate*`

Add:

```cpp
mlir::LLVM::LLVMFuncOp EcoRuntime::getOrCreateUtilsEqual(mlir::OpBuilder &builder) const {
    auto *ctx = builder.getContext();
    auto i64Ty = mlir::IntegerType::get(ctx, 64);
    auto i1Ty  = mlir::IntegerType::get(ctx, 1);

    auto fnTy = mlir::LLVM::LLVMFunctionType::get(i1Ty, { i64Ty, i64Ty });
    return getOrCreateFunc(builder, "Elm_Kernel_Utils_equal", fnTy);
}
```

#### Why

Keeps symbol declarations consistent with the rest of EcoToLLVM.

---

### 4.2 Create string literal values for comparison

#### Key point: reuse existing literal encoding

`eco.string_literal` lowering is already specified: empty string returns embedded constant `EmptyString (7<<40)` and non-empty becomes an LLVM global containing UTF-16 payload and an Elm string header.

#### Implementation strategy (recommended)

Factor out a helper in the "Types" lowering module so both:
- `eco.string_literal` op lowering, and
- `eco.case(case_kind="str")` lowering

can create an `i64` eco.value for a compile-time literal.

**File (recommended):** `runtime/src/codegen/Passes/EcoToLLVMTypes.cpp`
**Add helper signature (in a private header or anonymous namespace):**

```cpp
mlir::Value lowerStringLiteralValue(
    mlir::ConversionPatternRewriter &rewriter,
    mlir::Location loc,
    eco::detail::EcoRuntime runtime,
    llvm::StringRef utf8);
```

**Behavior:**
- if `utf8.empty()` -> return `i64` constant representing embedded EmptyString (as per encoding)
- else -> create/lookup a global like `eco.string_literal` lowering does and return it as `i64`

If you don't want to factor right now, you may duplicate minimal logic in ControlFlow, but factoring avoids drift and is strongly recommended.

---

### 4.3 Lower `eco.case` `"str"` into a comparison chain

**File:** `runtime/src/codegen/Passes/EcoToLLVMControlFlow.cpp`
**Where:** in the `CaseOp` lowering pattern

#### Dispatch

Detect string case:

```cpp
auto caseKindAttr = op.getCaseKindAttr();
bool isStrCase = caseKindAttr && caseKindAttr.getValue() == "str";
if (isStrCase) {
    return lowerStringCase(op, adaptor, rewriter, runtime);
}
```

#### `lowerStringCase` contract

Inputs:
- `scrutinee` is already lowered to `i64` (eco.value becomes i64 by type converter)
- `op.getStringPatternsAttr()` contains `N-1` patterns
- `op.getAlternatives()` contains `N` regions, last is default

Algorithm:
1. Create `caseBlocks[i]` per alternative region.
2. Emit a chain of:
   - compare `scrutinee` against `pattern[i]` using `Elm_Kernel_Utils_equal(scrutinee, literal)`
   - `cf.cond_br` to case block `i` or next check/default
3. Default goes to last alt block.
4. Inline each region into the corresponding case block (as existing case lowering likely does).
5. Replace `eco.return` in regions with branch to merge (as existing lowering does for other case kinds).

#### Comparison creation detail

For each pattern:

```cpp
Value patVal = lowerStringLiteralValue(rewriter, loc, runtime, pattern);
Value eq = rewriter.create<LLVM::CallOp>(
    loc, runtime.getOrCreateUtilsEqual(rewriter),
    ValueRange{scrutinee, patVal}).getResult();
rewriter.create<cf::CondBranchOp>(loc, eq, caseBlocks[i], elseBlock);
```

#### Why

This matches the semantics already used for string tests (call `Elm_Kernel_Utils_equal` after constructing a literal).

---

## 5. Tests (must add)

### 5.1 MLIR textual round-trip / parsing

Add a new codegen test that verifies:
- `eco.case` prints `patterns = [...]` (or prints attribute `string_patterns = [...]`)
- verifier rejects missing patterns for `case_kind="str"`

**File:** `test/codegen/case_string_fanout.mlir` (new)

Example:

```mlir
// RUN: ecoc -emit=mlir -verify-diagnostics %s | FileCheck %s

func.func @main() {
  %s = eco.string_literal "foo" : !eco.value
  eco.case %s [0, 1, 2] result_types [!eco.value] {
    eco.return %s : !eco.value
  }, {
    eco.return %s : !eco.value
  }, {
    eco.return %s : !eco.value
  } { case_kind = "str", string_patterns = ["foo", "bar"] }
  return
}

// CHECK: case_kind = "str"
// CHECK: string_patterns = ["foo", "bar"]
```

(Adjust syntax to match your custom assembly format once implemented.)

### 5.2 End-to-end Elm test (recommended)

Add an Elm snippet that forces a 3-way string fanout:

```elm
which s =
  case s of
    "foo" -> 1
    "bar" -> 2
    _     -> 3
```

This is the exact scenario that is currently broken by tag collapse.

---

## 6. Summary of All Files to Modify

### Runtime (C++ / MLIR dialect)

| File | Change |
|------|--------|
| `runtime/src/codegen/Ops.td` | Add `string_patterns` attribute to `Eco_CaseOp` args; update op description for `"str"` |
| `runtime/src/codegen/EcoOps.cpp` | `CaseOp::verify()`: require `string_patterns` for `"str"`, enforce `N-1` patterns vs `N` regions, enforce element types are `StringAttr`, (recommended) enforce tags count equals alternatives count; custom parser/printer: parse/print `patterns = [...]` or `string_patterns = [...]` |
| `runtime/src/codegen/Passes/EcoToLLVMInternal.h` | Add `EcoRuntime::getOrCreateUtilsEqual` declaration |
| `runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp` | Implement `getOrCreateUtilsEqual` |
| `runtime/src/codegen/Passes/EcoToLLVMTypes.cpp` | Factor or add helper to create an `i64` eco string value for a UTF-8 literal (empty -> embedded constant, non-empty -> global), matching existing string literal lowering semantics |
| `runtime/src/codegen/Passes/EcoToLLVMControlFlow.cpp` | Detect `case_kind == "str"`; lower via `lowerStringCase` comparison chain calling `Elm_Kernel_Utils_equal` |

### Compiler (Elm)

| File | Change |
|------|--------|
| `compiler/src/Compiler/Generate/MLIR/Ops.elm` | Add `ecoCaseString` builder |
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | Modify `generateFanOutGeneral`: if `"str"`: strict pattern extraction (crash on non-`DT.IsStr`), positional tags, call `ecoCaseString`; else: unchanged path |

**Note:** You do **not** need to change `Patterns.testToTagInt` for correctness once string fanout stops using tags; it can remain returning 0 for `DT.IsStr`.

### Tests

| File | Change |
|------|--------|
| `test/codegen/case_string_fanout.mlir` (new) | Verify IR includes patterns and round-trips / lowers |

---

## 7. Open Questions

1. **String literal creation in LLVM**: How are string constants created?
   - Option A: Global string constant + runtime call to wrap as eco.value
   - Option B: Call runtime function that interns the string
   - **Recommended**: Factor out existing `eco.string_literal` lowering logic

2. **Empty string handling**: Need to ensure empty string patterns work correctly (use `eco.constant EmptyString` semantic)

3. **Should 2-way string cases also use this path?** Currently they go through Chain which works. Could unify for consistency, or leave Chain path for 2-way cases.
