# Mutually Recursive Let-Bound Closures — Stage 6 Fix Report

## Symptom

Compiling the stage-5 compiler MLIR with `eco-boot-native` fails:

```
loc("compiler/build-kernel/bin/eco-compiler.mlir":826257:16):
error: operand #0 does not dominate this use
```

The offending region (inside `Terminal_Main_lambda_15903$cap`, a capture body
from the GLSL parser's `buildExpressionParser`):

```mlir
%100 = "eco.papCreate"(%101) { ...lambda_15919$cap, num_captured=1 } : (!eco.value) -> !eco.value
%101 = "eco.papCreate"(%98, %91, %100, %96, %99) { ...lambda_15917$cap, num_captured=5 } : (!eco.value, !eco.value, !eco.value, !eco.value, !eco.value) -> !eco.value
```

`%100` captures `%101` and `%101` captures `%100` — mutually recursive
closures. The two MLIR ops are emitted in sequence, so `%100` references
`%101` before `%101` is defined and MLIR's dominator check rejects the
program.

## Source

`Language.GLSL.Parser.buildExpressionParser` introduces mutually recursive
let bindings in the local `makeParser`:

```elm
rassocP x = Combine.choice [ ...termP |> Combine.andThen rassocP1..., ... ]
rassocP1 x = Combine.or (rassocP x) (Combine.succeed x)
lassocP x = Combine.choice [ ...termP |> Combine.andThen lassocP1..., ... ]
lassocP1 x = Combine.or (lassocP x) (Combine.succeed x)
```

`rassocP` and `rassocP1` reference each other via closure captures; same
for `lassocP` / `lassocP1`. Each pair compiles to two `eco.papCreate`s that
forward-reference each other.

## Root Cause

`Expr.elm generateLet` already handles let-rec groups by:

1. Collecting every name in the let chain (`collectLetBoundNames`).
2. Allocating placeholder SSA vars for each name up front
   (`addPlaceholderMappings`).
3. Generating each binding's RHS with those placeholders in scope, so sibling
   references resolve to the placeholder SSA ids.
4. Renaming the RHS's last op's result to the binding's placeholder with
   `forceResultVar`, so the `eco.papCreate` that builds the closure directly
   defines the placeholder.

This works for *self*-recursion: `hasSelfCapture` / `fixSelfCaptures` replaces
self-operand uses with a Unit placeholder and tags `self_capture_indices` on
the op, which the backend interprets by storing the closure's own HPointer
at the marked slots after `alloc_closure`.

It does **not** handle *cross*-recursion. When binding X's RHS references a
later sibling Y, the MLIR contains `papCreate(%P_X, ..., %P_Y, ...)` *before*
Y's `papCreate` defines `%P_Y`. MLIR's dominator check rejects it.

A trace attribute added to `eco.project.custom` during investigation (since
reverted) confirmed this by inspecting `fieldInfo` and `resultType` — the
problem is not in the shape registry but in the emission order of the
closures themselves.

## Fix

Introduce a new op, `eco.closure.patch_capture`, that stores a value into an
already-allocated closure's capture slot, lowered directly to an LLVM store.
Then, in the frontend, detect forward-sibling operands during let-rec
emission, replace them with a Unit placeholder, and emit
`eco.closure.patch_capture` once every sibling has landed.

### Emission strategy

For a let-rec group that compiles to:

```
%x_ph = papCreate(..., %y_ph, ...)
%y_ph = papCreate(..., %x_ph, ...)
```

where `%x_ph` is emitted first, the fix rewrites to:

```
%unit = eco.constant kind=unit
%x_ph = papCreate(..., %unit, ...)     -- Unit placeholder at y's slot
%y_ph = papCreate(..., %x_ph, ...)     -- %x_ph already defined, fine
eco.closure.patch_capture %x_ph, %y_ph {index = <slot>}
```

SSA dominance is satisfied: the patch op is emitted *after* both closures
and names each via their forceResultVar'd placeholder. Its backend lowering
resolves `%x_ph` to a raw pointer, GEPs to the chosen capture slot, and
stores the HPointer of `%y_ph` there — the same memory-store tail that
`self_capture_indices` already performs inside `PapCreateOpLowering`.

### Patches

#### 1. New MLIR op — `runtime/src/codegen/Ops.td`

```tablegen
def Eco_PatchClosureCaptureOp : Eco_Op<"closure.patch_capture", []> {
  let summary = "Patch a newly-created closure's captured slot";
  let description = [{
    Store `value` into capture slot `index` of `closure`. Used to break
    mutually recursive closure captures in let-rec groups: emit each
    papCreate with a Unit placeholder for any capture that points at a
    sibling whose own papCreate has not been emitted yet, then, after
    all siblings are defined, emit `eco.closure.patch_capture` to fix up
    each deferred slot. The closure must have been created in the same
    region and not yet escaped.

    `index` refers to the capture slot (0-based, same convention as
    `eco.papCreate`'s `captured` operand positions and the
    `self_capture_indices` attribute). Slots are stored as i64 at
    `layout::ClosureValuesOffset + index * layout::PtrSize`.
  }];

  let arguments = (ins
    Eco_Value:$closure,
    Eco_Value:$value,
    I64Attr:$index
  );
  let results = (outs);
}
```

#### 2. Backend lowering — `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp`

New conversion pattern (added after `PapCreateOpLowering`):

```cpp
struct PatchClosureCaptureOpLowering : public OpConversionPattern<PatchClosureCaptureOp> {
    const EcoRuntime &runtime;

    PatchClosureCaptureOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx, const EcoRuntime &runtime) :
        OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult matchAndRewrite(PatchClosureCaptureOp op, OpAdaptor adaptor,
                                  ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i8Ty  = IntegerType::get(ctx, 8);
        auto i64Ty = IntegerType::get(ctx, 64);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        auto resolveFunc = runtime.getOrCreateResolveHPtr(rewriter);

        // Adapted operands: !eco.value lowers to ptr addrspace(1).
        Value closureHPtr = adaptor.getClosure();
        Value valueHPtr   = adaptor.getValue();

        // Resolve closure's HPointer to a raw pointer for GEP + store.
        auto resolveCall = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{closureHPtr});
        Value closurePtr = resolveCall.getResult();

        // The capture slot stores the i64 encoding of the HPointer.
        Value storeValue = valueHPtr;
        if (isa<LLVM::LLVMPointerType>(storeValue.getType())) {
            storeValue = closureStoreValueToI64(rewriter, loc, storeValue);
        }

        int64_t idx = op.getIndex();
        int64_t valueOffset = layout::ClosureValuesOffset + idx * layout::PtrSize;
        auto offsetConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
            rewriter.getI64IntegerAttr(valueOffset));
        auto valuePtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, closurePtr,
            ValueRange{offsetConst});
        rewriter.create<LLVM::StoreOp>(loc, storeValue, valuePtr);

        rewriter.eraseOp(op);
        return success();
    }
};
```

Registered alongside the other closure patterns:

```cpp
patterns.add<PapCreateOpLowering>(typeConverter, ctx, runtime);
patterns.add<PatchClosureCaptureOpLowering>(typeConverter, ctx, runtime);   // new
patterns.add<PapExtendOpLowering>(typeConverter, ctx, runtime);
```

The pattern mirrors the tail of `PapCreateOpLowering`'s capture-store loop
(and the identical `self_capture_indices` handler) — the only differences
are (a) it starts from an already-allocated closure instead of allocating one
and (b) the stored value is the op's `value` operand rather than the
closure's own HPointer.

#### 3. Frontend MLIR builder — `compiler/src/Compiler/Generate/MLIR/Ops.elm`

Added export and builder:

```elm
ecoPatchClosureCapture : Ctx.Context -> String -> Int -> String -> ( Ctx.Context, MlirOp )
ecoPatchClosureCapture ctx closureVar slotIndex valueVar =
    let
        attrs =
            Dict.fromList
                [ ( "_operand_types"
                  , ArrayAttr Nothing [ TypeAttr Types.ecoValue, TypeAttr Types.ecoValue ]
                  )
                , ( "index", IntAttr (Just I64) slotIndex )
                ]
    in
    mlirOp ctx "eco.closure.patch_capture"
        |> opBuilder.withOperands [ closureVar, valueVar ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build
```

#### 4. Context extension — `compiler/src/Compiler/Generate/MLIR/Context.elm`

New record type and field:

```elm
type alias PendingPatch =
    { closureVar : String          -- SSA var of the closure whose capture we need to patch
    , slotIndex : Int               -- Capture slot index (0-based, matches papCreate operand position)
    , siblingPlaceholder : String  -- SSA var of the sibling — emit the patch once it is defined
    }

type alias Context =
    { ...
    , pendingPatches : List PendingPatch -- Deferred capture fix-ups
    }
```

Initialization in `initContext` adds `pendingPatches = []`.

`resetDefinedSsaVars` also drops pending patches (a patch must not cross a
function-scope boundary):

```elm
resetDefinedSsaVars initialVars ctx =
    { ctx
        | definedSsaVars = Set.fromList initialVars
        , pendingPatches = []
    }
```

`PendingPatch` is re-exported from the module.

#### 5. Let-rec integration — `compiler/src/Compiler/Generate/MLIR/Expr.elm`

Two new helpers just below `fixSelfCaptures` / `hasSelfCapture`:

```elm
fixForwardSiblingRefs :
    Set.Set String            -- sibling placeholders in the current let-rec group
    -> Set.Set String         -- definedSsaVars at this point
    -> String                 -- unitVar to substitute at forward-reference slots
    -> List MlirOp
    -> ( List MlirOp, List Ctx.PendingPatch )
fixForwardSiblingRefs siblingPlaceholders definedVars unitVar ops =
    -- For every eco.papCreate, replace any operand that names a sibling
    -- placeholder whose defining op has not been emitted yet with `unitVar`,
    -- emitting a PendingPatch for each replacement.
    ...
```

```elm
drainResolvedPatches :
    Ctx.Context
    -> List Ctx.PendingPatch
    -> ( List MlirOp, List Ctx.PendingPatch, Ctx.Context )
drainResolvedPatches ctx patches =
    let
        ( resolved, deferred ) =
            List.partition
                (\p -> Set.member p.siblingPlaceholder ctx.definedSsaVars)
                patches

        ( reversedNewOps, ctxAfter ) =
            List.foldl
                (\p ( acc, c ) ->
                    let
                        ( c1, op ) =
                            Ops.ecoPatchClosureCapture c p.closureVar p.slotIndex p.siblingPlaceholder
                    in
                    ( op :: acc, c1 )
                )
                ( [], ctx )
                resolved
    in
    ( List.reverse reversedNewOps, deferred, ctxAfter )
```

The `MonoDef` branch of `generateLet` threads these in. Ordering matters —
self-capture fix and `forceResultVar` run first, then forward-ref fix, so
that the patch records the binding's *final* SSA var (post rename):

```elm
( fixedResult, _ ) =
    if hasSelfCapture placeholderVar rawResult.ops then
        ...fixSelfCaptures...
    else
        ( rawResult, rawResult.ctx )

( forcedResult, effectiveVar ) =
    if ... then ( fixedResult, fixedResult.resultVar )
    else ( forceResultVar placeholderVar fixedResult, placeholderVar )

siblingPlaceholderSet =
    forcedResult.ctx.currentLetSiblings
        |> Dict.values
        |> List.map .ssaVar
        |> List.filter (\v -> v /= placeholderVar)
        |> Set.fromList

hasForwardRef =
    List.any
        (\op -> op.name == "eco.papCreate"
            && List.any
                (\o -> Set.member o siblingPlaceholderSet
                    && not (Set.member o forcedResult.ctx.definedSsaVars))
                op.operands)
        forcedResult.ops

exprResult =
    if hasForwardRef then
        let
            ( unitVar2, ctxWithUnit3 ) = Ctx.freshVar forcedResult.ctx
            ( ctxWithUnit4, unitOp2 )  = Ops.ecoConstantUnit ctxWithUnit3 unitVar2

            ( rewrittenOps, newPatches ) =
                fixForwardSiblingRefs
                    siblingPlaceholderSet
                    ctxWithUnit4.definedSsaVars
                    unitVar2
                    forcedResult.ops
        in
        { forcedResult
            | ops = unitOp2 :: rewrittenOps
            , ctx = { ctxWithUnit4 | pendingPatches = ctxWithUnit4.pendingPatches ++ newPatches }
        }
    else
        forcedResult
```

After `Ctx.addVarMapping` (which inserts the binding's placeholder into
`definedSsaVars`), we drain any now-resolvable patches. Their ops land
*before* the body ops so they dominate every downstream use:

```elm
ctx1 =
    Ctx.addVarMapping name effectiveVar exprResult.resultType scopedCtx
        |> Ctx.addDecoderExpr name expr
        |> trackExternBoxedVar name expr

( patchOps, remainingPatches, ctxAfterDrain ) =
    drainResolvedPatches ctx1 ctx1.pendingPatches

ctx1Drained =
    { ctxAfterDrain | pendingPatches = remainingPatches }

bodyResult =
    generateExpr ctx1Drained body

...
in
{ ops = exprResult.ops ++ patchOps ++ bodyResult.ops
, resultVar = bodyResult.resultVar
, resultType = bodyResult.resultType
, ctx = ctxOut
, isTerminated = finalIsTerminated
}
```

Note that patches propagate through the ctx as successive `generateLet`
calls recurse into the let-chain body. Each binding's `drainResolvedPatches`
emits only those patches whose target is *now* defined; later bindings
drain the rest.

#### 6. Regression test — `test/elm/src/MutualLetRecClosuresTest.elm`

An E2E test with two let-bound `evenP` / `oddP` functions that capture each
other by name. The produced MLIR has the same shape as the bootstrap site:
two `eco.papCreate`s plus one `eco.closure.patch_capture` per group.
Generated MLIR:

```mlir
%5  = eco.constant kind=unit
%1  = eco.papCreate(%5)                                        -- unit placeholder
%2  = eco.papCreate(%1)                                        -- uses %1, defined
"eco.closure.patch_capture"(%1, %2) {index = 0 : i64} : ...
```

The test also passes through `eco-boot-native` (native lowering), so it
guards both MLIR-parse and LLVM-lowering paths.

## Verification

- `TEST_FILTER=MutualLetRec cmake --build build --target full` — passes.
- `TEST_FILTER=PolyStep cmake --build build --target full` — all 5 still pass.
- `cmake --build build --target full` — all 1133 E2E tests pass.
- Stage 6 of the bootstrap advances past `Terminal_Main_lambda_15903$cap`.
  It now halts on an **unrelated** pre-existing lowering bug in the string
  `eco.case` of `Builder_Reporting_parseYesNoResponse_$_30611`
  (`operand type mismatch: 'i64' != '!llvm.ptr<1>'`).

## Known limitation: GC safety under arbitrary GC timing

`PapCreateOpLowering` already mutates freshly allocated closures through the
`self_capture_indices` path — same shape of resolve + GEP + store. The
difference is that self-capture stores the *closure's own* HPointer: parent
and child are the same object, so any parent-age vs child-age invariant is
trivially satisfied.

`eco.closure.patch_capture` stores a *sibling's* HPointer. A minor GC may
fire between the two `papCreate` calls (each is an allocation + safepoint)
and age the first closure past the second. Elm's nursery GC assumes strict
child-age ≥ parent-age monotonicity — see `NurserySpace.cpp:421-428`
("Elm's immutability means no old→young pointers exist, so no write barrier
or remembered set is needed") and the assertion inside `evacuate()`. A
minor GC between the allocations can therefore turn the patch into a
child-younger-than-parent write and, down the line, a missed old→young root.

In practice this has not triggered because both `papCreate`s in a let-rec
group almost always land in the same nursery block without an intervening
minor GC — the 1133 E2E tests pass, and the native run of
`MutualLetRecClosuresTest` produces the expected output. But the hazard is
real and deserves a follow-up.

## Option 1: eliminate the hazard by making allocation + patches atomic

Instead of emitting an arbitrary number of `papCreate`s followed by
`eco.closure.patch_capture`s — each `papCreate` being a possible safepoint —
emit the entire let-rec group through a single runtime helper (or a single
MLIR op) that performs all allocations and capture stores between two
safepoints, so no minor GC can fire in the middle. Concretely:

1. **New MLIR op**, e.g. `eco.closure.papCreateGroup`. Operands:
    - for each sibling, `arity`, `num_captured`, `unboxed_bitmap`,
      `function`, optional `_fast_evaluator`.
    - for each sibling, the list of capture operands **excluding** sibling
      cross-references. Cross-references are expressed as a separate attribute
      holding `(producer_sibling_index, consumer_sibling_index, slot_index)`
      triples. All operands are real SSA values, so no Unit placeholders are
      needed and there are no forward SSA references.

2. **Frontend**. `generateLet` detects a let-rec group with cross-captures
    and emits a single `eco.closure.papCreateGroup` op at the top of the
    group. The `ctx.pendingPatches` machinery and the `fixForwardSiblingRefs`
    / `drainResolvedPatches` helpers are removed. Normal (non-mutual)
    `papCreate` emission is unchanged.

3. **Backend lowering**. A single `matchAndRewrite`:
    - emit one safepoint marker that conservatively lists every operand.
    - call `alloc_closure` for every sibling.
    - store normal captures into each sibling's `values[]` exactly like
      `PapCreateOpLowering` does today.
    - store cross-reference HPointers using the attribute-provided
      `(producer, consumer, slot)` triples.
    - no intervening LLVM `call` to any non-gc-leaf function, so RS4GC never
      inserts a safepoint between the first allocation and the last sibling
      store.
    - replace the op with a `ValueRange` of all sibling HPointers.

The invariant the nursery GC relies on —
"children age ≥ parent age" — is restored because all siblings are allocated
in one uninterrupted run and therefore start with age 0. No minor GC can
fire between allocations, so no sibling can be promoted ahead of the
cross-reference write.

Cost: one new op, one rewrite pattern, and a mildly larger code path in
`generateLet`. Benefit: a guaranteed-safe construction that is independent
of whatever the nursery happens to be doing at runtime.
