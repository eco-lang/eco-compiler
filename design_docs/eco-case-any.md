I’ll restate the overall design, then focus on *concrete* changes to `Compiler/Generate/CodeGen/MLIR.elm` so that codegen uses `eco.case` directly on `i1` (Bool) scrutinees, without boxing.

---

## 1. Dialect / verifier / SCF changes (recap)

These are as in the previous design, summarized:

### 1.1 Dialect: `eco.case` scrutinee → `Eco_AnyValue`

In `Ops.td`, change `Eco_CaseOp` to accept `Eco_AnyValue` instead of `Eco_Value`:

```tablegen
def Eco_CaseOp : Eco_Op<"case", [
    DeclareOpInterfaceMethods<MemoryEffectsOpInterface>
]> {
  ...

  let arguments = (ins
    Eco_AnyValue:$scrutinee,              // was Eco_Value
    DenseI64ArrayAttr:$tags,
    OptionalAttr<ArrayAttr>:$caseResultTypes
  );

  ...
}
``` 

Semantics:

- Scrutinee may be:
    - `!eco.value` (ADT/list/custom).
    - `i1` (Bool) — what we care about for `if` and Bool `case`.
- `tags` is still an array of `i64` discriminants.
- `caseResultTypes` is an `ArrayAttr` of `TypeAttr` listing the MLIR result types (e.g. `[!eco.value]`, `[i64, !eco.value]`) for SCF lowering.

### 1.2 Verifier: restrict scrutinee types and enforce result types

In `Eco_CaseOp::verify()`:

- Allow only:
    - `eco::ValueType` (`!eco.value`).
    - `i1` (Bool).
- For `i1` scrutinee, ensure all `tags` are `0` or `1`.
- For any scrutinee:
    - Check `tags.size()` matches `alternatives.size()` or is `alternatives.size() - 1` (default).
    - If `caseResultTypes` is present, assert it’s an array of `TypeAttr` and that all reachable `eco.return` in the alternatives have operand types equal to this list (per the SCF design doc) .

This keeps the IR well‑typed and gives the SCF pass explicit result type info.

### 1.3 SCF lowering: two paths in `EcoControlFlowToSCF`

In `EcoControlFlowToSCF`’s pattern for `eco.case`:

- If `scrutinee` is `!eco.value`:
    - Exactly as designed already: emit `eco.get_tag %scrutinee : !eco.value -> i32` then lower to:
        - `scf.if` for 2‑way cases, or
        - `scf.index_switch` for multi‑way cases, using `result_types` for the SCF result tuple types.
- If `scrutinee` is `i1`:
    - Lower to a single `scf.if` using the `i1` directly, cloning the case regions and rewriting `eco.return` → `scf.yield` with `result_types` as the SCF result types.
- If scrutinee is any other type:
    - `return failure()` from the pattern; `createControlFlowLoweringPass()` will then lower this `eco.case` directly to `cf` as today .

That’s the compiler‑side prerequisite. Now, with that in place, the Elm backend is free to emit `eco.case` over `i1` conditions.

---

## 2. Elm MLIR codegen changes (`MLIR.elm`)

Your current `MLIR.elm` backend has *two* different control‑flow strategies:

- For **explicit `if` expressions**, it already uses `scf.if` and `scf.yield` on an `i1` condition, via helpers `scfIf` and `scfYield` .
- For **decision‑tree cases** (`MonoCase` via `generateCase` / `generateFanOutGeneral`), it uses `eco.case` but assumes the scrutinee is always `!eco.value`, and for Bool pattern matches it falls back to `scf.if` (see `generateBoolFanOut`, `generateChainGeneral`, `generateChainForBoolADT`) because `eco.case` only worked on pointers  .

After the dialect change, you can:

- Continue using `scf.if` for `MonoIf` if you like (non‑tail, expression‑level conditionals).
- But for decision‑tree driven *pattern matches* on Bool, you can now unify them with the ADT path and emit `eco.case` directly on `i1` without boxing or falling back to SCF.

Below I’ll spell out the concrete Elm changes.

### 2.1 Ensure `ecoCase` builder doesn’t assume `eco.value`

You already have an `ecoCase` helper in the design doc . The actual `MLIR.elm` code, however, calls it as:

```elm
( ctx3, caseOp ) =
    ecoCase fallbackRes.ctx scrutineeVar ecoValue tags allRegions [ resultTy ]
```

inside `generateFanOutGeneral` , which implies the real signature is something like:

```elm
ecoCase :
    Context
    -> String        -- scrutinee SSA var
    -> MlirType      -- scrutinee type
    -> List Int
    -> List MlirRegion
    -> List MlirType
    -> ( Context, MlirOp )
```

and it likely sets `_operand_types` based on that `MlirType`.

Adjust this builder so that it works for any scrutinee type (`I1`, `I64`, `ecoValue`, etc.):

```elm
ecoCase :
    Context
    -> String
    -> MlirType
    -> List Int
    -> List MlirRegion
    -> List MlirType
    -> ( Context, MlirOp )
ecoCase ctx scrutinee scrutineeTy tags regions resultTypes =
    let
        -- Dialect-level attributes
        baseAttrs =
            Dict.fromList
                [ ( "tags"
                  , I64ArrayAttr (List.map IntAttr tags)
                  )
                ]

        -- Optional result_types : ArrayAttr of TypeAttr
        attrsWithResults =
            if List.isEmpty resultTypes then
                baseAttrs
            else
                Dict.insert "result_types"
                    (ArrayAttr (List.map TypeAttr resultTypes))
                    baseAttrs

        -- Optional _operand_types attribute for round-tripping/testing
        operandTypesAttr =
            Dict.singleton "_operand_types"
                (ArrayAttr Nothing [ TypeAttr scrutineeTy ])

        attrs =
            Dict.union attrsWithResults operandTypesAttr
    in
    mlirOp ctx "eco.case"
        |> opBuilder.withOperands [ scrutinee ]
        |> opBuilder.withRegions regions
        |> opBuilder.withAttrs attrs
        |> opBuilder.build
```

Key change: we **pass the actual MLIR type of the scrutinee** (`I1` for Bool, `ecoValue` for ADT, etc.), rather than always `ecoValue`.

All existing call sites that already use `ecoValue` as scrutinee type (e.g. `generateFanOutGeneral`) stay correct; new Bool use‑sites will pass `I1`.

### 2.2 Decision‑tree Bool FanOut: replace `scf.if` with `eco.case`

Current code for Bool fanout uses `scf.if` because `eco.case` used to require a pointer scrutinee:

```elm
-- Current comment:
-- Handle Bool FanOut with scf.if instead of eco.case.
-- eco.case uses eco.get_tag which dereferences the value as a pointer,
-- but Bool values are embedded constants that can't be dereferenced. 
generateBoolFanOut : ... -> ExprResult
generateBoolFanOut ctx root path edges fallback resultTy =
    let
        ( pathOps, boolVar, ctx1 ) =
            generateDTPath ctx root path I1
        ...
        ( ctx4, ifOp ) =
            scfIf ctx3b boolVar ifResultVar thenRegion elseRegion resultTy
    in
    { ops = pathOps ++ [ ifOp ], ... }
```

With the new dialect & SCF lowering, you can now use `eco.case` on `boolVar : i1` directly.

**New `generateBoolFanOut`**:

```elm
generateBoolFanOut :
    Context
    -> Name.Name
    -> DT.Path
    -> List ( DT.Test, Mono.Decider Mono.MonoChoice )
    -> Mono.Decider Mono.MonoChoice
    -> MlirType
    -> ExprResult
generateBoolFanOut ctx root path edges fallback resultTy =
    let
        -- 1. Scrutinee: Bool as i1
        ( pathOps, boolVar, ctx1 ) =
            generateDTPath ctx root path I1

        -- 2. Find True and False branches (unchanged helper)
        ( trueBranch, falseBranch ) =
            findBoolBranches edges fallback

        -- 3. Generate True branch (tag 1)
        thenRes =
            generateDecider ctx1 root trueBranch resultTy

        ( ctx2, thenRet ) =
            ecoReturn thenRes.ctx thenRes.resultVar resultTy

        thenRegion =
            mkRegion [] (thenRes.ops ++ [ thenRet ])

        -- 4. Generate False branch (tag 0 or default)
        elseRes =
            generateDecider ctx2 root falseBranch resultTy

        ( ctx3, elseRet ) =
            ecoReturn elseRes.ctx elseRes.resultVar resultTy

        elseRegion =
            mkRegion [] (elseRes.ops ++ [ elseRet ])

        -- 5. eco.case on Bool: we treat tag 1 as True, default as False.
        -- Tags = [1], regions = [thenRegion, elseRegion]; result_types = [resultTy]
        ( ctx4, caseOp ) =
            ecoCase ctx3 boolVar I1 [ 1 ] [ thenRegion, elseRegion ] [ resultTy ]

        -- 6. ExprResult: we don't actually use the dummy result at runtime,
        -- control exits via eco.return inside the regions. But our ExprResult
        -- contract wants a "resultVar", so we can just reuse boolVar or make
        -- a dummy; code outside won't rely on it when case is in tail position.
        dummyResultVar =
            boolVar
    in
    { ops = pathOps ++ [ caseOp ]
    , resultVar = dummyResultVar
    , resultType = resultTy
    , ctx = ctx4
    }
```

Changes:

- No boxing: `boolVar` is `i1` produced by `generateDTPath` with `targetType = I1` (you already do this) .
- No `scfIf` or `scfYield` in this path.
- The lowering pass will see an `eco.case` with scrutinee `i1` and handle it via the Bool path in SCF or CF lowering.

You can now delete (or stop using) the `scfIf` / `scfYield` helpers and the old `generateBoolFanOut` variant, at least for Eco‑only control‑flow builds for case expressions.

### 2.3 Chain nodes on Bool: use `eco.case` instead of `scf.if`

You currently have:

- `generateChainForBoolADT` and `generateChainGeneral`, both using `scf.if` on a computed `i1` condition, for the same “eco.case uses eco.get_tag” reason .

For Bool chains, the same transformation applies: after computing `condVar : i1` with `generateChainCondition`, you use a 2‑way `eco.case` instead of `scf.if`.

New `generateChainGeneral` sketch (for AND‑of‑tests on arbitrary Bool combos):

```elm
generateChainGeneral :
    Context
    -> Name.Name
    -> List ( DT.Path, DT.Test )          -- testChain
    -> Mono.Decider Mono.MonoChoice       -- success
    -> Mono.Decider Mono.MonoChoice       -- failure
    -> MlirType                            -- resultTy
    -> ExprResult
generateChainGeneral ctx root testChain success failure resultTy =
    let
        -- 1. Compute cond : i1 by combining individual tests (unchanged)
        ( condOps, condVar, ctx1 ) =
            generateChainCondition ctx root testChain

        -- 2. Generate success branch
        thenRes =
            generateDecider ctx1 root success resultTy

        ( ctx2, thenRet ) =
            ecoReturn thenRes.ctx thenRes.resultVar resultTy

        thenRegion =
            mkRegion [] (thenRes.ops ++ [ thenRet ])

        -- 3. Generate failure branch
        elseRes =
            generateDecider ctx2 root failure resultTy

        ( ctx3, elseRet ) =
            ecoReturn elseRes.ctx elseRes.resultVar resultTy

        elseRegion =
            mkRegion [] (elseRes.ops ++ [ elseRet ])

        -- 4. eco.case on Bool: tags [1] => region 0 for True, region 1 default False
        ( ctx4, caseOp ) =
            ecoCase ctx3 condVar I1 [ 1 ] [ thenRegion, elseRegion ] [ resultTy ]

        dummyVar =
            condVar
    in
    { ops = condOps ++ [ caseOp ]
    , resultVar = dummyVar
    , resultType = resultTy
    , ctx = ctx4
    }
```

`generateChainForBoolADT` (the simpler “case b of True/False” when the path itself is Bool) becomes just a thin wrapper around this pattern: compute the `i1` scrutinee, then call the same `eco.case`‑based helper.

### 2.4 General FanOut on ADTs stays unchanged (still `!eco.value`)

Your existing non‑Bool `generateFanOutGeneral` is already correct for ADTs:

- It calls `generateDTPath ctx root path ecoValue` to produce `scrutineeVar : !eco.value` .
- It computes `tags` from constructor tests via `testToTagInt`.
- It builds one region per edge plus a fallback, each ending in `eco.return`.
- It then calls `ecoCase ctx3 scrutineeVar ecoValue tags allRegions [ resultTy ]` .

No boxing changes are needed here; the scrutinee is already a pointer.

The only tweak you might consider is *dropping the comment* that says “eco.case only accepts !eco.value” since that’s no longer true; it now also accepts `i1`. Update the comment to something like:

```elm
-- eco.case normally matches on !eco.value (ADT tags) here.
-- For Bool patterns, generateBoolFanOut uses eco.case on i1 instead.
```

### 2.5 `generateIf`: optional switch from `scf.if` to `eco.case`

Right now, `generateIf` already produces:

- An `i1` condition via `generateExpr ctx condExpr`.
- An `scf.if` with two regions, each terminated by `scf.yield`, using helpers `scfIf` / `scfYield` .

With the dialect change, you have two options:

1. **Keep `scf.if` for `if` expressions.**  
   This is reasonable because `if` is an expression that returns a value in non‑tail position; SCF is a great fit, and SCF→CF→LLVM lowering is already in your pipeline.

2. **Or use `eco.case` for `if` too**, in line with the “control flow only in eco” philosophy in `mlir-case-codegen.md` .

If you want (2), the change is analogous to the decision‑tree Chain case, but without the Decider machinery:

```elm
generateIf :
    Context
    -> List ( Mono.MonoExpr, Mono.MonoExpr )
    -> Mono.MonoExpr
    -> ExprResult
generateIf ctx branches final =
    case branches of
        [] ->
            generateExpr ctx final

        ( condExpr, thenExpr ) :: restBranches ->
            let
                -- 1. Compute condition : i1
                condRes =
                    generateExpr ctx condExpr

                condVar =
                    condRes.resultVar

                -- 2. Type of the whole if-expression
                resultMonoType =
                    Mono.typeOf thenExpr

                resultMlirType =
                    monoTypeToMlir resultMonoType

                -- 3. Then branch
                thenRes =
                    generateExpr condRes.ctx thenExpr

                ( ctx1, thenRet ) =
                    ecoReturn thenRes.ctx thenRes.resultVar resultMlirType

                thenRegion =
                    mkRegion [] (thenRes.ops ++ [ thenRet ])

                -- 4. Else branch: recursively generate the rest of the chain
                elseRes =
                    generateIf ctx1 restBranches final

                ( ctx2, elseRet ) =
                    ecoReturn elseRes.ctx elseRes.resultVar resultMlirType

                elseRegion =
                    mkRegion [] (elseRes.ops ++ [ elseRet ])

                -- 5. Bool eco.case: tag 1 for True, default False
                ( ctx3, caseOp ) =
                    ecoCase ctx2 condVar I1 [ 1 ] [ thenRegion, elseRegion ] [ resultMlirType ]

                -- 6. Dummy ExprResult; control actually leaves via eco.return inside regions
                ( dummyVar, ctx4 ) =
                    freshVar ctx3

                ( ctx5, dummyOp ) =
                    ecoConstruct ctx4 dummyVar 0 0 0 []
            in
            { ops = condRes.ops ++ [ caseOp, dummyOp ]
            , resultVar = dummyVar
            , resultType = resultMlirType
            , ctx = ctx5
            }
```

This matches the design already written in `mlir-case-codegen.md` for Bool `if` via `eco.case` , but updated to *not* box the condition: we just pass `condVar : i1` to `ecoCase`.

If you keep `scf.if` for `MonoIf`, you can still apply the Bool‑`eco.case` model solely in the decision‑tree based `generateCase` / FanOut / Chain, which is probably enough to remove any need for boxing just to drive `eco.case`.

### 2.6 Cleanup: SCF helpers and comments

Given the above, you can simplify `MLIR.elm`:

- **If you move Bool FanOut and Chain to `eco.case`:**
    - `generateBoolFanOut`, `generateChainForBoolADT`, `generateChainGeneral`’s SCF‑based implementations can be removed or refactored to the `eco.case` versions.
    - Comments like “eco.case uses eco.get_tag which dereferences the value as a pointer, but Bool values are embedded constants that can't be dereferenced” are no longer correct and should be updated or removed .
- **If you also move `generateIf` to `eco.case`:**
    - You can drop `scfIf` and `scfYield` helpers entirely (unless you use SCF elsewhere for loops) .

SCF is still used in your *lowering pipeline* (Eco→SCF→CF→LLVM), but it no longer needs to appear in frontend‑emitted IR; SCF becomes an internal lowering target instead of a source dialect.

---

## 3. Net effect on boxing and codegen

With these changes:

- Conditions are always computed as raw `i1` (as they already are today).
- `eco.case` now accepts `i1` directly as `scrutinee : Eco_AnyValue`.
- Elm codegen never needs to box booleans just to pattern match; it emits:
    - `eco.case %cond : i1` for decision‑tree Bool cases and (optionally) `if` expressions.
- The Eco→SCF/CF/LLVM pipeline handles Bool scrutinees without any knowledge of boxing.

So the *only* boxing that remains is for true data (Ints/Floats/Chars/Bools being stored in records, tuples, closures, or passed through the boxed calling convention), not for control‑flow bookkeeping.

