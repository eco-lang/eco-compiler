# Fix String Case Lowering (Option B)

## Problem Summary

Multi-way string pattern matching (`case_kind = "str"`) is broken at two levels:

1. **Tag uniqueness (Elm codegen)**: All `IsStr` tests return tag 0 → non-unique tags
2. **Missing string comparison (LLVM lowering)**: The lowering extracts constructor tags instead of comparing strings

The existing plan (`fix-string-case-tags.md`) addresses #1 but not #2.

## Solution: Extend eco.case with String Literals

### Overview

1. Add `string_patterns` attribute to `eco.case` for `case_kind = "str"`
2. Update Elm codegen to emit string literals
3. Update LLVM lowering to generate string comparison chain

---

## Step 1: Extend eco.case Op Definition

**File:** `runtime/src/codegen/Ops.td`

Add optional `string_patterns` attribute:

```tablegen
let arguments = (ins
  Eco_AnyValue:$scrutinee,
  DenseI64ArrayAttr:$tags,
  OptionalAttr<ArrayAttr>:$caseResultTypes,
  StrAttr:$case_kind,
  OptionalAttr<ArrayAttr>:$string_patterns  // NEW: for case_kind="str"
);
```

Update description to document:
```
- `!eco.value` + `case_kind="str"`: String pattern matching.
  Requires `string_patterns` attribute containing string literals for each
  non-default alternative. The last alternative is the default (wildcard).
  Tags are branch indices [0, 1, ..., N] used after comparison.
```

---

## Step 2: Update eco.case Verifier

**File:** `runtime/src/codegen/EcoOps.cpp`

Add verification in `CaseOp::verify()`:

```cpp
// For string cases, verify string_patterns attribute
if (caseKind == "str") {
  auto stringPatternsAttr = getStringPatternsAttr();
  if (!stringPatternsAttr) {
    return emitOpError("case_kind 'str' requires 'string_patterns' attribute");
  }

  // string_patterns should have N-1 elements (last alt is default)
  size_t numAlts = getAlternatives().size();
  size_t numPatterns = stringPatternsAttr.size();
  if (numPatterns + 1 != numAlts) {
    return emitOpError("string_patterns has ") << numPatterns
           << " elements but expected " << (numAlts - 1)
           << " (one per non-default alternative)";
  }

  // Verify all elements are StringAttr
  for (auto attr : stringPatternsAttr) {
    if (!isa<StringAttr>(attr)) {
      return emitOpError("string_patterns must contain only string attributes");
    }
  }
}
```

---

## Step 3: Update eco.case Parser/Printer

**File:** `runtime/src/codegen/EcoOps.cpp`

Update custom parser to handle `string_patterns`:

```cpp
// After parsing case_kind, check for string_patterns
if (caseKind == "str") {
  if (succeeded(parser.parseOptionalKeyword("patterns"))) {
    if (parser.parseEqual())
      return failure();
    ArrayAttr patternsAttr;
    if (parser.parseAttribute(patternsAttr))
      return failure();
    result.addAttribute("string_patterns", patternsAttr);
  }
}
```

Update printer:
```cpp
if (auto patterns = op.getStringPatternsAttr()) {
  p << " patterns = " << patterns;
}
```

---

## Step 4: Update Elm Codegen - Ops.elm

**File:** `compiler/src/Compiler/Generate/MLIR/Ops.elm`

Add new function for string case:

```elm
ecoCaseString : Ctx.Context -> String -> MlirType -> List Int -> List String -> List MlirRegion -> List MlirType -> ( Ctx.Context, MlirOp )
ecoCaseString ctx scrutinee scrutineeType tags stringPatterns regions resultTypes =
    let
        attrsBase =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing [ TypeAttr scrutineeType ] )
                , ( "tags", ArrayAttr (Just I64) (List.map (\t -> IntAttr Nothing t) tags) )
                , ( "case_kind", StringAttr "str" )
                , ( "string_patterns", ArrayAttr Nothing (List.map StringAttr stringPatterns) )
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

---

## Step 5: Update Elm Codegen - Expr.elm

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

Modify `generateFanOutGeneral` to handle string cases specially:

```elm
generateFanOutGeneral ctx root path edges fallback resultTy =
    let
        edgeTests =
            List.map Tuple.first edges

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

        -- For string cases: use sequential tags and collect string literals
        ( tags, stringPatterns ) =
            if caseKind == "str" then
                let
                    edgeCount = List.length edges
                    sequentialTags = List.range 0 edgeCount  -- 0..N (includes fallback)
                    patterns = List.filterMap extractStringPattern edgeTests
                in
                ( sequentialTags, Just patterns )
            else
                let
                    edgeTags = List.map (\( test, _ ) -> Patterns.testToTagInt test) edges
                    fallbackTag = Patterns.computeFallbackTag edgeTests
                in
                ( edgeTags ++ [ fallbackTag ], Nothing )

        -- Generate regions for each edge...
        ( edgeRegions, ctx2 ) =
            List.foldl
                (\( _, subTree ) ( accRegions, accCtx ) ->
                    let
                        subRes = generateDecider accCtx root subTree resultTy
                        ( region, ctxAfterRegion ) = mkCaseRegionFromDecider subRes.ctx subRes.ops resultTy
                    in
                    ( accRegions ++ [ region ], ctxAfterRegion )
                )
                ( [], ctx1 )
                edges

        -- Generate fallback region
        fallbackRes = generateDecider ctx2 root fallback resultTy
        ( fallbackRegion, ctx2a ) = mkCaseRegionFromDecider fallbackRes.ctx fallbackRes.ops resultTy

        allRegions = edgeRegions ++ [ fallbackRegion ]

        -- Build eco.case - use string variant if we have patterns
        ( ctx3, caseOp ) =
            case stringPatterns of
                Just patterns ->
                    Ops.ecoCaseString ctx2a scrutineeVar scrutineeType tags patterns allRegions [ resultTy ]

                Nothing ->
                    Ops.ecoCase ctx2a scrutineeVar scrutineeType caseKind tags allRegions [ resultTy ]
    in
    { ops = pathOps ++ [ caseOp ]
    , resultVar = scrutineeVar
    , resultType = resultTy
    , ctx = ctx3
    }


extractStringPattern : DT.Test -> Maybe String
extractStringPattern test =
    case test of
        DT.IsStr s -> Just s
        _ -> Nothing
```

---

## Step 6: Update LLVM Lowering

**File:** `runtime/src/codegen/Passes/EcoToLLVMControlFlow.cpp`

Add string case handling in `CaseOpLowering::matchAndRewrite`:

```cpp
// After int/chr case check, add string case handling
bool isStrCase = caseKindAttr && caseKindAttr.getValue() == "str";

if (isStrCase) {
    return lowerStringCase(op, adaptor, rewriter);
}

// ... rest of existing code for ctor cases
```

Add new method `lowerStringCase`:

```cpp
LogicalResult
lowerStringCase(CaseOp op, OpAdaptor adaptor,
                ConversionPatternRewriter &rewriter) const {
    auto loc = op.getLoc();
    auto *ctx = rewriter.getContext();
    auto i1Ty = IntegerType::get(ctx, 1);

    Value scrutinee = adaptor.getScrutinee();
    auto alternatives = op.getAlternatives();
    auto stringPatterns = op.getStringPatternsAttr();

    if (!stringPatterns) {
        return op.emitOpError("string case missing string_patterns attribute");
    }

    Block *currentBlock = op->getBlock();
    Region *parentRegion = currentBlock->getParent();
    Block *originalOpBlock = op->getBlock();

    // Create merge block
    Block *mergeBlock = rewriter.createBlock(parentRegion);
    mergeBlock->moveBefore(currentBlock->getNextNode());

    // Create case blocks for each alternative
    SmallVector<Block *> caseBlocks;
    for (size_t i = 0; i < alternatives.size(); ++i) {
        Block *caseBlock = rewriter.createBlock(parentRegion);
        caseBlock->moveBefore(mergeBlock);
        caseBlocks.push_back(caseBlock);
    }

    // Move operations after eco.case to merge block
    {
        auto opsToMove = llvm::make_early_inc_range(
            llvm::make_range(std::next(Block::iterator(op)), originalOpBlock->end()));
        for (Operation &opToMove : opsToMove) {
            opToMove.moveBefore(mergeBlock, mergeBlock->end());
        }
    }

    // Generate comparison chain: if (s == "pat0") goto alt0; else if (s == "pat1") goto alt1; ...
    // Last alternative is default (no comparison needed)

    rewriter.setInsertionPointToEnd(currentBlock);

    Block *nextCheckBlock = currentBlock;

    for (size_t i = 0; i < stringPatterns.size(); ++i) {
        auto patternAttr = cast<StringAttr>(stringPatterns[i]);
        StringRef pattern = patternAttr.getValue();

        // Create string literal for comparison
        Value patternStr = createStringLiteral(rewriter, loc, pattern);

        // Call Elm_Kernel_Utils_equal(scrutinee, patternStr)
        auto equalFunc = runtime.getOrCreateUtilsEqual(rewriter);
        auto cmpResult = rewriter.create<LLVM::CallOp>(
            loc, equalFunc, ValueRange{scrutinee, patternStr});
        Value isEqual = cmpResult.getResult();

        // If this is not the last pattern, create next check block
        Block *elseBlock;
        if (i + 1 < stringPatterns.size()) {
            elseBlock = rewriter.createBlock(parentRegion);
            elseBlock->moveBefore(mergeBlock);
        } else {
            // Last pattern's else goes to default (last alternative)
            elseBlock = caseBlocks.back();
        }

        // Branch: if equal, goto caseBlocks[i]; else goto elseBlock
        rewriter.create<cf::CondBranchOp>(
            loc, isEqual, caseBlocks[i], ValueRange{}, elseBlock, ValueRange{});

        // Continue building from else block
        if (i + 1 < stringPatterns.size()) {
            rewriter.setInsertionPointToEnd(elseBlock);
            nextCheckBlock = elseBlock;
        }
    }

    // If there are no patterns (shouldn't happen), branch to default
    if (stringPatterns.empty()) {
        rewriter.create<cf::BranchOp>(loc, caseBlocks.back());
    }

    // Inline each alternative region (same as existing code)
    Value originalScrutinee = op->getOperand(0);

    for (size_t i = 0; i < alternatives.size(); ++i) {
        Region &altRegion = alternatives[i];
        Block *caseBlock = caseBlocks[i];

        if (altRegion.empty()) {
            rewriter.setInsertionPointToEnd(caseBlock);
            rewriter.create<cf::BranchOp>(loc, mergeBlock);
            continue;
        }

        Block &entryBlock = altRegion.front();
        rewriter.inlineBlockBefore(&entryBlock, caseBlock, caseBlock->end());
    }

    // Replace uses of original scrutinee
    for (Block *caseBlock : caseBlocks) {
        for (Operation &blockOp : *caseBlock) {
            blockOp.replaceUsesOfWith(originalScrutinee, scrutinee);
        }
    }

    // Fix terminators - replace eco.return with branch to merge
    for (Block *caseBlock : caseBlocks) {
        if (caseBlock->empty())
            continue;
        Operation *term = caseBlock->getTerminator();
        if (isa<ReturnOp>(term)) {
            rewriter.setInsertionPoint(term);
            rewriter.create<cf::BranchOp>(loc, mergeBlock);
            rewriter.eraseOp(term);
        }
    }

    rewriter.eraseOp(op);
    return success();
}
```

Also need to add helper methods:
- `createStringLiteral` - create a string constant (may need runtime call or global)
- `runtime.getOrCreateUtilsEqual` - get/declare `Elm_Kernel_Utils_equal` function

---

## Step 7: Add Runtime Helper Declaration

**File:** `runtime/src/codegen/EcoRuntime.cpp` (or equivalent)

Add method to get/create `Elm_Kernel_Utils_equal`:

```cpp
LLVM::LLVMFuncOp EcoRuntime::getOrCreateUtilsEqual(OpBuilder &builder) {
    auto module = builder.getBlock()->getParent()->getParentOfType<ModuleOp>();
    auto funcName = "Elm_Kernel_Utils_equal";

    if (auto func = module.lookupSymbol<LLVM::LLVMFuncOp>(funcName)) {
        return func;
    }

    auto *ctx = builder.getContext();
    auto i64Ty = IntegerType::get(ctx, 64);
    auto i1Ty = IntegerType::get(ctx, 1);

    // Elm_Kernel_Utils_equal(a: i64, b: i64) -> i1
    auto funcType = LLVM::LLVMFunctionType::get(i1Ty, {i64Ty, i64Ty});

    OpBuilder::InsertionGuard guard(builder);
    builder.setInsertionPointToStart(module.getBody());

    return builder.create<LLVM::LLVMFuncOp>(
        builder.getUnknownLoc(), funcName, funcType);
}
```

---

## Validation

1. **Build runtime** (C++ changes):
   ```bash
   cmake --build build
   ```

2. **Run codegen tests** to verify eco.case parsing/printing:
   ```bash
   cmake --build build --target check-codegen
   ```

3. **Run E2E tests** focusing on string cases:
   ```bash
   TEST_FILTER="CaseString" cmake --build build --target check
   ```

4. **Manual verification** - inspect generated MLIR for:
   ```elm
   which s =
     case s of
       "foo" -> 1
       "bar" -> 2
       _     -> 3
   ```

   Should produce:
   ```mlir
   eco.case %s : !eco.value [0, 1, 2] result_types [!eco.value] {
     eco.return %one : !eco.value
   }, {
     eco.return %two : !eco.value
   }, {
     eco.return %three : !eco.value
   } {case_kind = "str", string_patterns = ["foo", "bar"]}
   ```

---

## Files Modified

| File | Change |
|------|--------|
| `runtime/src/codegen/Ops.td` | Add `string_patterns` attribute |
| `runtime/src/codegen/EcoOps.cpp` | Verifier + parser/printer for string_patterns |
| `runtime/src/codegen/Passes/EcoToLLVMControlFlow.cpp` | Add `lowerStringCase` method |
| `runtime/src/codegen/EcoRuntime.cpp` | Add `getOrCreateUtilsEqual` helper |
| `compiler/src/Compiler/Generate/MLIR/Ops.elm` | Add `ecoCaseString` function |
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | Update `generateFanOutGeneral` |

---

## Open Questions

1. **String literal creation in LLVM**: How are string constants created?
   - Option A: Global string constant + runtime call to wrap as eco.value
   - Option B: Call runtime function that interns the string

2. **Empty string handling**: Need to ensure empty string patterns work correctly (use `eco.constant EmptyString` semantic)

3. **Should 2-way string cases also use this path?** Currently they go through Chain which works. Could unify for consistency, or leave Chain path for 2-way cases.
