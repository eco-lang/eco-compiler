Below is a concrete, end‑to‑end design for the **“still curried at Mono stage”** approach, assuming:
- You **keep** the existing uncurrying of *simple, directly nested* lambdas (the `peelFunctionChain` + `specializeLambda` you already added) .
- You want **curried semantics** for wrappers like `\x -> let ... in \y -> ...` and `\x -> case ... of Match -> \y -> ...`, but you do **not** want to flatten those into a single stage.
- MLIR codegen understands both:
  - **Fully uncurried** functions (simple chains, top-level defs), and
  - **Curried / staged** functions where one call stage returns another closure.

I’ll organize this as:

1. High‑level semantics and invariants
2. Type changes (Mono types and TypeSubst)
3. Monomorphization changes (Specialize.elm)
4. MLIR Types helpers (`stageArity`, etc.)
5. MLIR Expr changes (PAP + closure calls)
6. Invariants/tests to update
- You **keep** the existing uncurrying of *simple, directly nested* lambdas (the `peelFunctionChain` + `specializeLambda` you already added) .
- You want **curried semantics** for wrappers like `\x -> let ... in \y -> ...` and `\x -> case ... of Match -> \y -> ...`, but you do **not** want to flatten those into a single stage.
- MLIR codegen understands both:
  - **Fully uncurried** functions (simple chains, top-level defs), and
  - **Curried / staged** functions where one call stage returns another closure.

I’ll organize this as:

1. High‑level semantics and invariants
2. Type changes (Mono types and TypeSubst)
3. Monomorphization changes (Specialize.elm)
4. MLIR Types helpers (`stageArity`, etc.)
5. MLIR Expr changes (PAP + closure calls)
6. Invariants/tests to update
- You **keep** the existing uncurrying of *simple, directly nested* lambdas (the `peelFunctionChain` + `specializeLambda` you already added) .
- You want **curried semantics** for wrappers like `\x -> let ... in \y -> ...` and `\x -> case ... of Match -> \y -> ...`, but you do **not** want to flatten those into a single stage.
- MLIR codegen understands both:
  - **Fully uncurried** functions (simple chains, top-level defs), and
  - **Curried / staged** functions where one call stage returns another closure.

I’ll organize this as:

1. High‑level semantics and invariants
2. Type changes (Mono types and TypeSubst)
3. Monomorphization changes (Specialize.elm)
4. MLIR Types helpers (`stageArity`, etc.)
5. MLIR Expr changes (PAP + closure calls)
6. Invariants/tests to update
---
## 1. High‑level semantics
### 1.1 Function representation

At the **Mono** level:
- `Mono.MFunction argTypes resultType` represents **one call stage**:
  - It expects `argTypes` “now”.
  - It returns `resultType` (which may or may not be another `MFunction`).

- A *fully uncurried* 3‑arg function:
  ```elm
  \x y z -> body
  ```

  will be represented as:
  ```elm
  Mono.MFunction [xTy, yTy, zTy] retTy
  ```

  and as a single `Mono.MonoClosure` with:
  ```elm
  closureInfo.params = [ (x,xTy), (y,yTy), (z,zTy) ]
  ```

- A **curried** wrapper:
  ```elm
  \x -> let ... in \y -> body
  ```

  will be represented as:
  ```elm
  -- Outer function:
  Mono.MFunction [xTy] (Mono.MFunction [yTy] retTy)
  ```

  and as a `Mono.MonoClosure` with:
  ```elm
  closureInfo.params = [ (x,xTy) ]   -- first stage only
  ```

  The inner `\y -> ...` itself becomes another `Mono.MonoClosure` value with type `Mono.MFunction [yTy] retTy`.
### 1.2 Key invariants

We enforce:
- **Stage arity invariant (core):**
  ```text
  For every MonoClosure with type T:
      let stageArgTypes = outermost arg list of T
      length closureInfo.params == length stageArgTypes
  ```

- **Optional uncurried optimization invariant:**

  For lambdas that are *pure chains* of directly nested lambdas (no intervening let/case/etc.), we additionally normalize them to a single uncurried stage:
  ```text
  For such closures: monoType = MFunction flatArgs finalRet
                     length flatArgs == length closureInfo.params
                     and there is no nested MFunction in finalRet
  ```

Wrappers that cannot be directly peeled (because of `let`/`case`) use the first invariant only (curried).
---
## 2. Type changes — `TypeSubst.applySubst`

**Goal:** Make `Mono.MFunction` genuinely represent stages:
- **No flattening** of `TLambda` chains inside `applySubst`.
- Keep flattening helpers (`extractParamTypes`, `flattenFunctionType`, `decomposeFunctionType`) for when you explicitly want an uncurried view.
### 2.1 Change `applySubst` TLambda case

**File:** `compiler/src/Compiler/Generate/Monomorphize/TypeSubst.elm`
Current TLambda case:
```elm
Can.TLambda from to ->
    let
        argMono =
            applySubst subst from

        resultMono =
            applySubst subst to
    in
    case resultMono of
        Mono.MFunction restArgs ret ->
            -- Flatten curried chain: prepend this arg to existing function args
            Mono.MFunction (argMono :: restArgs) ret

        _ ->
            -- Base case: single argument function
            Mono.MFunction [ argMono ] resultMono
```

**Change it to:**
```elm
Can.TLambda from to ->
    let
        argMono =
            applySubst subst from

        resultMono =
            applySubst subst to
    in
    -- Do NOT flatten across stages. Each TLambda is one stage.
    Mono.MFunction [ argMono ] resultMono
```

Explanation:
- You’re removing the automatic chain‑flattening.
- A canonical type `a -> b -> c` now maps to:
  ```elm
  MFunction [a] (MFunction [b] c)
  ```

- Existing helpers:
  - `TypeSubst.extractParamTypes` still flattens **all** argument lists across nested `MFunction`s .
  - `Compiler.Generate.Monomorphize.Closure.flattenFunctionType` also flattens to `(args, finalRet)` for wrapper generation .
  - `Compiler.Generate.MLIR.Types.decomposeFunctionType` does the same at codegen time .
These remain valid and become your “explicit uncurrying” utilities.
---
## 3. Monomorphization — `specializeLambda`

You already have:
- `peelFunctionChain : TOpt.Expr -> (List (Name, Can.Type), TOpt.Expr)` that gathers chained lambda params until the first non‑lambda body .
- `specializeLambda` that:
  - uses `applySubst`,
  - flattens types via `extractParamTypes`,
  - and currently enforces `length allParams == length funcTypeParams` (Option A) .

We’ll split `specializeLambda` into two modes:

- **Mode A – Fully uncurried (simple pure lambda chains)**:
  - e.g. `\x -> \y -> \z -> body`
  - No let/case in between; `peelFunctionChain` gets all of `[x,y,z]`.

- **Mode B – Curried stage (wrappers)**:
  - e.g. `\x -> let ... in \y -> body`
  - `peelFunctionChain` only sees `[x]` (outer stage).
- `peelFunctionChain : TOpt.Expr -> (List (Name, Can.Type), TOpt.Expr)` that gathers chained lambda params until the first non‑lambda body .
- `specializeLambda` that:
  - uses `applySubst`,
  - flattens types via `extractParamTypes`,
  - and currently enforces `length allParams == length funcTypeParams` (Option A) .

We’ll split `specializeLambda` into two modes:

- **Mode A – Fully uncurried (simple pure lambda chains)**:
  - e.g. `\x -> \y -> \z -> body`
  - No let/case in between; `peelFunctionChain` gets all of `[x,y,z]`.

- **Mode B – Curried stage (wrappers)**:
  - e.g. `\x -> let ... in \y -> body`
  - `peelFunctionChain` only sees `[x]` (outer stage).
- `peelFunctionChain : TOpt.Expr -> (List (Name, Can.Type), TOpt.Expr)` that gathers chained lambda params until the first non‑lambda body .
- `specializeLambda` that:
  - uses `applySubst`,
  - flattens types via `extractParamTypes`,
  - and currently enforces `length allParams == length funcTypeParams` (Option A) .

We’ll split `specializeLambda` into two modes:

- **Mode A – Fully uncurried (simple pure lambda chains)**:
  - e.g. `\x -> \y -> \z -> body`
  - No let/case in between; `peelFunctionChain` gets all of `[x,y,z]`.

- **Mode B – Curried stage (wrappers)**:
  - e.g. `\x -> let ... in \y -> body`
  - `peelFunctionChain` only sees `[x]` (outer stage).
### 3.1 New `specializeLambda` logic

**File:** `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm`
Replace the body of `specializeLambda` with:
```elm
specializeLambda :
    TOpt.Expr
    -> Can.Type
    -> Substitution
    -> MonoState
    -> ( Mono.MonoExpr, MonoState )
specializeLambda lambdaExpr canType subst state =
    let
        -- Stage-aware MonoType (nested MFunction chain, no flattening)
        monoType0 : Mono.MonoType
        monoType0 =
            TypeSubst.applySubst subst canType

        -- Total flattened args & final return (for fully-peelable lambdas)
        ( flatArgTypes, flatRetType ) =
            Closure.flattenFunctionType monoType0

        totalArity : Int
        totalArity =
            List.length flatArgTypes

        -- Peel syntactic chain of lambdas
        ( allParams, finalBodyExpr ) =
            peelFunctionChain lambdaExpr

        paramCount : Int
        paramCount =
            List.length allParams

        isFullyPeelable : Bool
        isFullyPeelable =
            paramCount == totalArity && totalArity > 0

        -- Stage param types for curried mode: outermost MFunction args
        stageParamTypes : List Mono.MonoType
        stageParamTypes =
            case monoType0 of
                Mono.MFunction args _ ->
                    args

                _ ->
                    []

        -- Effective MonoType we will attach to this closure:
        --  - Uncurried for fully-peelable chains
        --  - Original (curried) for wrappers / first-stage lambdas
        effectiveMonoType : Mono.MonoType
        effectiveMonoType =
            if isFullyPeelable then
                -- Single-stage, uncurried function
                Mono.MFunction flatArgTypes flatRetType
            else
                -- Multi-stage or wrapper: keep nested structure
                monoType0

        -- Effective param types to pair with params
        effectiveParamTypes : List Mono.MonoType
        effectiveParamTypes =
            if isFullyPeelable then
                flatArgTypes
            else
                -- Curried: only outer stage params
                case monoType0 of
                    Mono.MFunction args _ ->
                        if paramCount > List.length args then
                            Utils.Crash.crash
                                ("specializeLambda: more params ("
                                    ++ String.fromInt paramCount
                                    ++ ") than outer-stage args ("
                                    ++ String.fromInt (List.length args)
                                    ++ ") for curried lambda"
                                )

                        else
                            List.take paramCount args

                    _ ->
                        -- Not a function type at all
                        []
    in
    -- Now build Mono params, body, captures as before, but using effectiveMonoType
    let
        deriveParamType : Int -> ( Name, Can.Type ) -> ( Name, Mono.MonoType )
        deriveParamType idx ( name, paramCanType ) =
            let
                funcParamTypeAtIdx =
                    List.drop idx effectiveParamTypes |> List.head

                substType =
                    TypeSubst.applySubst subst paramCanType

                finalType =
                    case funcParamTypeAtIdx of
                        Just funcParamType ->
                            case paramCanType of
                                Can.TVar _ ->
                                    funcParamType

                                _ ->
                                    case substType of
                                        Mono.MVar _ _ ->
                                            funcParamType

                                        _ ->
                                            substType

                        Nothing ->
                            substType
            in
            ( name, finalType )

        monoParams : List ( Name, Mono.MonoType )
        monoParams =
            List.indexedMap deriveParamType allParams

        lambdaId =
            Mono.AnonymousLambda state.currentModule state.lambdaCounter

        newVarTypes =
            List.foldl
                (\( name, monoParamType ) vt ->
                    Dict.insert identity name monoParamType vt
                )
                state.varTypes
                monoParams

        stateWithLambda =
            { state
                | lambdaCounter = state.lambdaCounter + 1
                , varTypes = newVarTypes
            }

        augmentedSubst =
            List.foldl
                (\( ( _, paramCanType ), ( _, monoParamType ) ) s ->
                    case paramCanType of
                        Can.TVar varName ->
                            Dict.insert identity varName monoParamType s

                        _ ->
                            s
                )
                subst
                (List.map2 Tuple.pair allParams monoParams)

        ( monoBody, stateAfter ) =
            specializeExpr finalBodyExpr augmentedSubst stateWithLambda

        captures =
            Closure.computeClosureCaptures monoParams monoBody

        closureInfo =
            { lambdaId = lambdaId
            , captures = captures
            , params = monoParams
            }
    in
    ( Mono.MonoClosure closureInfo monoBody effectiveMonoType, stateAfter )
```

Explanation:
- **Fully-peelable case (simple lambda chains):**
  - `paramCount == totalArity` and `totalArity > 0`
  - `effectiveMonoType = MFunction flatArgTypes flatRetType` — uncurried.
  - `allParams` covers every argument; this recovers Option‑A‑style uncurrying, but *only* for pure chains.

- **Curried/wrapper case:**
  - `paramCount < totalArity` (or `totalArity == 0`).
  - `effectiveMonoType = monoType0` — nested `MFunction` chain.
  - `effectiveParamTypes` = outermost stage args, truncated to the number of syntactic params you actually see.
  - This handles:

    ```elm
    \x -> let ... in \y -> ...
    -- monoType0: MFunction [xTy] (MFunction [yTy] ret)
    -- flatArgTypes: [xTy, yTy]
    -- allParams: [x]
    -- effectiveParamTypes: [xTy]
    -- closure.params: [(x,xTy)]
    ```

- You keep **all** the existing environment setup, capture analysis, etc. 

In `specializeExpr`, the `TOpt.Function` and `TOpt.TrackedFunction` cases remain:
- **Fully-peelable case (simple lambda chains):**
  - `paramCount == totalArity` and `totalArity > 0`
  - `effectiveMonoType = MFunction flatArgTypes flatRetType` — uncurried.
  - `allParams` covers every argument; this recovers Option‑A‑style uncurrying, but *only* for pure chains.

- **Curried/wrapper case:**
  - `paramCount < totalArity` (or `totalArity == 0`).
  - `effectiveMonoType = monoType0` — nested `MFunction` chain.
  - `effectiveParamTypes` = outermost stage args, truncated to the number of syntactic params you actually see.
  - This handles:

    ```elm
    \x -> let ... in \y -> ...
    -- monoType0: MFunction [xTy] (MFunction [yTy] ret)
    -- flatArgTypes: [xTy, yTy]
    -- allParams: [x]
    -- effectiveParamTypes: [xTy]
    -- closure.params: [(x,xTy)]
    ```

- You keep **all** the existing environment setup, capture analysis, etc. 

In `specializeExpr`, the `TOpt.Function` and `TOpt.TrackedFunction` cases remain:
```elm
TOpt.Function params body canType ->
    specializeLambda (TOpt.Function params body canType) canType subst state

TOpt.TrackedFunction params body canType ->
    specializeLambda (TOpt.TrackedFunction params body canType) canType subst state
```

no change required there .
---
## 4. MLIR Types helpers — stage arity

**File:** `compiler/src/Compiler/Generate/MLIR/Types.elm`
You currently export:
```elm
, isFunctionType, functionArity, countTotalArity, decomposeFunctionType, isEcoValueType
```

Add two helpers:
```elm
{-| Stage parameter types: outermost MFunction argument list. -}
stageParamTypes : Mono.MonoType -> List Mono.MonoType
stageParamTypes monoType =
    case monoType of
        Mono.MFunction argTypes _ ->
            argTypes

        _ ->
            []


{-| Stage arity: number of arguments expected in the current stage. -}
stageArity : Mono.MonoType -> Int
stageArity monoType =
    List.length (stageParamTypes monoType)
```

And export them:
```elm
, isFunctionType, functionArity, countTotalArity, decomposeFunctionType
, stageParamTypes, stageArity, isEcoValueType
```

Explanation:
- `stageArity` is your **primary** notion of “how many args does this function value expect right now?”.
- `countTotalArity` stays around as a helper when you explicitly want the flattened total; PAP and closure calls must **not** use it anymore.
---
## 5. MLIR Expr — PAP and closure calls

You already have:
- PAP creation in `generateClosure` building `eco.papCreate` with:
  ```elm
  arity = numCaptured + List.length closureInfo.params
  ```

  and `num_captured = numCaptured` . This remains correct; with our stage semantics, `List.length closureInfo.params` is **stage arity** for that function symbol.
- PAP extension and indirect closure calls using `remaining_arity = Types.countTotalArity funcType` after the previous Option‑A change.

Now we want:

- For **PAP extension + closure calls**: use `Types.stageArity funcType`.
- PAP extension and indirect closure calls using `remaining_arity = Types.countTotalArity funcType` after the previous Option‑A change.

Now we want:

- For **PAP extension + closure calls**: use `Types.stageArity funcType`.
- PAP extension and indirect closure calls using `remaining_arity = Types.countTotalArity funcType` after the previous Option‑A change.

Now we want:

- For **PAP extension + closure calls**: use `Types.stageArity funcType`.
### 5.1 Update `remaining_arity` in `Expr.elm`

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`
Search for all places where `remaining_arity` is set for `eco.papExtend` and indirect `eco.call`. You’ll see patterns like:
```elm
remainingArity : Int
remainingArity =
    Types.countTotalArity funcType
```

and in the closure application path:
```elm
remainingArity : Int
remainingArity =
    Types.countTotalArity funcType
```

**Change them to:**
```elm
remainingArity : Int
remainingArity =
    Types.stageArity funcType
```

This appears in at least two paths (closure call via variable and via already‑evaluated `funcResult`) where `papExtend` is built  .
Explanation:
- For **uncurried** simple lambdas:
  - `funcType` is `MFunction [a,b,c] ret`.
  - `stageArity funcType = 3` equals total arity; behavior is identical to Option A.

- For **curried** wrappers:
  - `funcType` is `MFunction [xTy] (MFunction [yTy] ret)`.
  - `stageArity funcType = 1`.
  - `eco.papExtend remaining_arity=1` precisely describes “this closure expects one more arg in this stage”.

This is sufficient because **Elm source only calls such curried wrappers with one argument per call** (e.g. `f x` then later `(f x) y`), so you never see more args than `stageArity` in a single call for those cases.
- For **uncurried** simple lambdas:
  - `funcType` is `MFunction [a,b,c] ret`.
  - `stageArity funcType = 3` equals total arity; behavior is identical to Option A.

- For **curried** wrappers:
  - `funcType` is `MFunction [xTy] (MFunction [yTy] ret)`.
  - `stageArity funcType = 1`.
  - `eco.papExtend remaining_arity=1` precisely describes “this closure expects one more arg in this stage”.

This is sufficient because **Elm source only calls such curried wrappers with one argument per call** (e.g. `f x` then later `(f x) y`), so you never see more args than `stageArity` in a single call for those cases.
### 5.2 Leave `generateClosure` PAP creation unchanged

In `generateClosure` (same file), keep:
```elm
numCaptured =
    List.length closureInfo.captures

arity =
    numCaptured + List.length closureInfo.params
```

and the `eco.papCreate` attrs as they are .
Explanation:
- `arity - num_captured = length params = stageArity` for that function symbol.
- This matches the dialect semantics (“remaining after create is `arity - num_captured`”) and gives the correct **stage remaining** for the closure produced by `papCreate`.
---
## 6. Invariants and tests
### 6.1 MONO_016 — relax / restate

Current MONO_016 (Option A) says:
> No `MonoClosure` has fewer params than `countTotalArity` of its MonoType. 

Under the new design, this is **not** true for curried wrappers (they have fewer params than total flattened arity). Replace it with:

> For every `MonoClosure` with function type `MFunction`,  
> `length closureInfo.params == length (Types.stageParamTypes monoType)`.

Concretely, in `design_docs/invariants.csv`:
> No `MonoClosure` has fewer params than `countTotalArity` of its MonoType. 

Under the new design, this is **not** true for curried wrappers (they have fewer params than total flattened arity). Replace it with:

> For every `MonoClosure` with function type `MFunction`,  
> `length closureInfo.params == length (Types.stageParamTypes monoType)`.

Concretely, in `design_docs/invariants.csv`:
> No `MonoClosure` has fewer params than `countTotalArity` of its MonoType. 

Under the new design, this is **not** true for curried wrappers (they have fewer params than total flattened arity). Replace it with:

> For every `MonoClosure` with function type `MFunction`,  
> `length closureInfo.params == length (Types.stageParamTypes monoType)`.

Concretely, in `design_docs/invariants.csv`:
> No `MonoClosure` has fewer params than `countTotalArity` of its MonoType. 

Under the new design, this is **not** true for curried wrappers (they have fewer params than total flattened arity). Replace it with:

> For every `MonoClosure` with function type `MFunction`,  
> `length closureInfo.params == length (Types.stageParamTypes monoType)`.

Concretely, in `design_docs/invariants.csv`:
- Change the MONO_016 row description accordingly.
- Update any test that enforced the old invariant, e.g. `WrapperCurriedCallsTest.elm`, to check **stage arity** instead of total arity.
### 6.2 CGEN_052 — PAP remaining arity

Your design docs already say CGEN_052 should track:
- For `eco.papCreate`:
  ```text
  papRemaining = arity - num_captured
  ```

- For `eco.papExtend`:
  ```text
  expected_remaining_arity = sourcePapRemaining (before this application)
  ```

and that this is “remaining arity before application”, matching `Eco_PapExtendOp`’s semantics .
With the stage‑curried design:
- `papRemaining` is **per‑stage** remaining arity, not flattened total arity.
- Update the test implementation (e.g. `PapExtendArityTest.elm` / `PapExtendArity.elm`) to:

  - Track `papRemaining = arity - num_captured` at `eco.papCreate`.
  - For each `eco.papExtend`, assert that the `remaining_arity` attribute matches the source closure’s tracked remaining (before subtracting new args).
  - (Optionally) track the resulting closure’s new remaining as `sourceRemaining - numNewArgs` if you want to validate chaining.

No additional changes are needed once `Expr.elm` uses `Types.stageArity` to set `remaining_arity`.
- `papRemaining` is **per‑stage** remaining arity, not flattened total arity.
- Update the test implementation (e.g. `PapExtendArityTest.elm` / `PapExtendArity.elm`) to:

  - Track `papRemaining = arity - num_captured` at `eco.papCreate`.
  - For each `eco.papExtend`, assert that the `remaining_arity` attribute matches the source closure’s tracked remaining (before subtracting new args).
  - (Optionally) track the resulting closure’s new remaining as `sourceRemaining - numNewArgs` if you want to validate chaining.

No additional changes are needed once `Expr.elm` uses `Types.stageArity` to set `remaining_arity`.
---
## 7. Summary checklist of code changes

**Type system / Monomorphization:**
- `TypeSubst.elm`:
  - Remove TLambda flattening in `applySubst` (see §2.1) .
  - Keep `extractParamTypes` as a flattening helper.

- `Specialize.elm`:
  - Keep `peelFunctionChain` as is .
  - Replace `specializeLambda` body with stage‑aware logic in §3.1, selecting:
    - **uncurried** `effectiveMonoType` for fully peelable lambda chains,
    - **curried** nested `effectiveMonoType` for wrappers.

**Closures / wrappers:**

- `Closure.elm`:
  - No semantic changes; `flattenFunctionType` still flattens for `ensureCallableTopLevel` and alias closures, which is correct even with nested `MFunction`s .

**MLIR Types:**

- `Types.elm`:
  - Add `stageParamTypes` and `stageArity` helpers and export them (§4) .

**MLIR Expr (PAP + closure calls):**

- `Expr.elm`:
  - In all places that set `remaining_arity` on `eco.papExtend` or indirect `eco.call`, change:

    ```elm
    remainingArity = Types.countTotalArity funcType
    ```

    to:

    ```elm
    remainingArity = Types.stageArity funcType
    ```

    as seen in the closure call paths around the papExtend generation  .
  - Leave `generateClosure`’s PAP creation arity as‑is.

**Invariants & tests:**

- `design_docs/invariants.csv`:
  - Update MONO_016 description to “closure params length equals stage arity”.
- `compiler/tests/Compiler/Generate/Monomorphize/WrapperCurriedCallsTest.elm`:
  - Check stage arity instead of `countTotalArity`.
- `compiler/tests/Compiler/Generate/CodeGen/PapExtendArity*.elm`:
  - Implement CGEN_052 based on per‑stage remaining arity (`arity - num_captured`) as described in §6.2.
- `TypeSubst.elm`:
  - Remove TLambda flattening in `applySubst` (see §2.1) .
  - Keep `extractParamTypes` as a flattening helper.

- `Specialize.elm`:
  - Keep `peelFunctionChain` as is .
  - Replace `specializeLambda` body with stage‑aware logic in §3.1, selecting:
    - **uncurried** `effectiveMonoType` for fully peelable lambda chains,
    - **curried** nested `effectiveMonoType` for wrappers.

**Closures / wrappers:**

- `Closure.elm`:
  - No semantic changes; `flattenFunctionType` still flattens for `ensureCallableTopLevel` and alias closures, which is correct even with nested `MFunction`s .

**MLIR Types:**

- `Types.elm`:
  - Add `stageParamTypes` and `stageArity` helpers and export them (§4) .

**MLIR Expr (PAP + closure calls):**

- `Expr.elm`:
  - In all places that set `remaining_arity` on `eco.papExtend` or indirect `eco.call`, change:

    ```elm
    remainingArity = Types.countTotalArity funcType
    ```

    to:

    ```elm
    remainingArity = Types.stageArity funcType
    ```

    as seen in the closure call paths around the papExtend generation  .
  - Leave `generateClosure`’s PAP creation arity as‑is.

**Invariants & tests:**

- `design_docs/invariants.csv`:
  - Update MONO_016 description to “closure params length equals stage arity”.
- `compiler/tests/Compiler/Generate/Monomorphize/WrapperCurriedCallsTest.elm`:
  - Check stage arity instead of `countTotalArity`.
- `compiler/tests/Compiler/Generate/CodeGen/PapExtendArity*.elm`:
  - Implement CGEN_052 based on per‑stage remaining arity (`arity - num_captured`) as described in §6.2.
- `TypeSubst.elm`:
  - Remove TLambda flattening in `applySubst` (see §2.1) .
  - Keep `extractParamTypes` as a flattening helper.

- `Specialize.elm`:
  - Keep `peelFunctionChain` as is .
  - Replace `specializeLambda` body with stage‑aware logic in §3.1, selecting:
    - **uncurried** `effectiveMonoType` for fully peelable lambda chains,
    - **curried** nested `effectiveMonoType` for wrappers.

**Closures / wrappers:**

- `Closure.elm`:
  - No semantic changes; `flattenFunctionType` still flattens for `ensureCallableTopLevel` and alias closures, which is correct even with nested `MFunction`s .

**MLIR Types:**

- `Types.elm`:
  - Add `stageParamTypes` and `stageArity` helpers and export them (§4) .

**MLIR Expr (PAP + closure calls):**

- `Expr.elm`:
  - In all places that set `remaining_arity` on `eco.papExtend` or indirect `eco.call`, change:

    ```elm
    remainingArity = Types.countTotalArity funcType
    ```

    to:

    ```elm
    remainingArity = Types.stageArity funcType
    ```

    as seen in the closure call paths around the papExtend generation  .
  - Leave `generateClosure`’s PAP creation arity as‑is.

**Invariants & tests:**

- `design_docs/invariants.csv`:
  - Update MONO_016 description to “closure params length equals stage arity”.
- `compiler/tests/Compiler/Generate/Monomorphize/WrapperCurriedCallsTest.elm`:
  - Check stage arity instead of `countTotalArity`.
- `compiler/tests/Compiler/Generate/CodeGen/PapExtendArity*.elm`:
  - Implement CGEN_052 based on per‑stage remaining arity (`arity - num_captured`) as described in §6.2.
- `TypeSubst.elm`:
  - Remove TLambda flattening in `applySubst` (see §2.1) .
  - Keep `extractParamTypes` as a flattening helper.

- `Specialize.elm`:
  - Keep `peelFunctionChain` as is .
  - Replace `specializeLambda` body with stage‑aware logic in §3.1, selecting:
    - **uncurried** `effectiveMonoType` for fully peelable lambda chains,
    - **curried** nested `effectiveMonoType` for wrappers.

**Closures / wrappers:**

- `Closure.elm`:
  - No semantic changes; `flattenFunctionType` still flattens for `ensureCallableTopLevel` and alias closures, which is correct even with nested `MFunction`s .

**MLIR Types:**

- `Types.elm`:
  - Add `stageParamTypes` and `stageArity` helpers and export them (§4) .

**MLIR Expr (PAP + closure calls):**

- `Expr.elm`:
  - In all places that set `remaining_arity` on `eco.papExtend` or indirect `eco.call`, change:

    ```elm
    remainingArity = Types.countTotalArity funcType
    ```

    to:

    ```elm
    remainingArity = Types.stageArity funcType
    ```

    as seen in the closure call paths around the papExtend generation  .
  - Leave `generateClosure`’s PAP creation arity as‑is.

**Invariants & tests:**

- `design_docs/invariants.csv`:
  - Update MONO_016 description to “closure params length equals stage arity”.
- `compiler/tests/Compiler/Generate/Monomorphize/WrapperCurriedCallsTest.elm`:
  - Check stage arity instead of `countTotalArity`.
- `compiler/tests/Compiler/Generate/CodeGen/PapExtendArity*.elm`:
  - Implement CGEN_052 based on per‑stage remaining arity (`arity - num_captured`) as described in §6.2.
- `TypeSubst.elm`:
  - Remove TLambda flattening in `applySubst` (see §2.1) .
  - Keep `extractParamTypes` as a flattening helper.

- `Specialize.elm`:
  - Keep `peelFunctionChain` as is .
  - Replace `specializeLambda` body with stage‑aware logic in §3.1, selecting:
    - **uncurried** `effectiveMonoType` for fully peelable lambda chains,
    - **curried** nested `effectiveMonoType` for wrappers.

**Closures / wrappers:**

- `Closure.elm`:
  - No semantic changes; `flattenFunctionType` still flattens for `ensureCallableTopLevel` and alias closures, which is correct even with nested `MFunction`s .

**MLIR Types:**

- `Types.elm`:
  - Add `stageParamTypes` and `stageArity` helpers and export them (§4) .

**MLIR Expr (PAP + closure calls):**

- `Expr.elm`:
  - In all places that set `remaining_arity` on `eco.papExtend` or indirect `eco.call`, change:

    ```elm
    remainingArity = Types.countTotalArity funcType
    ```

    to:

    ```elm
    remainingArity = Types.stageArity funcType
    ```

    as seen in the closure call paths around the papExtend generation  .
  - Leave `generateClosure`’s PAP creation arity as‑is.

**Invariants & tests:**

- `design_docs/invariants.csv`:
  - Update MONO_016 description to “closure params length equals stage arity”.
- `compiler/tests/Compiler/Generate/Monomorphize/WrapperCurriedCallsTest.elm`:
  - Check stage arity instead of `countTotalArity`.
- `compiler/tests/Compiler/Generate/CodeGen/PapExtendArity*.elm`:
  - Implement CGEN_052 based on per‑stage remaining arity (`arity - num_captured`) as described in §6.2.
- `TypeSubst.elm`:
  - Remove TLambda flattening in `applySubst` (see §2.1) .
  - Keep `extractParamTypes` as a flattening helper.

- `Specialize.elm`:
  - Keep `peelFunctionChain` as is .
  - Replace `specializeLambda` body with stage‑aware logic in §3.1, selecting:
    - **uncurried** `effectiveMonoType` for fully peelable lambda chains,
    - **curried** nested `effectiveMonoType` for wrappers.

**Closures / wrappers:**

- `Closure.elm`:
  - No semantic changes; `flattenFunctionType` still flattens for `ensureCallableTopLevel` and alias closures, which is correct even with nested `MFunction`s .

**MLIR Types:**

- `Types.elm`:
  - Add `stageParamTypes` and `stageArity` helpers and export them (§4) .

**MLIR Expr (PAP + closure calls):**

- `Expr.elm`:
  - In all places that set `remaining_arity` on `eco.papExtend` or indirect `eco.call`, change:

    ```elm
    remainingArity = Types.countTotalArity funcType
    ```

    to:

    ```elm
    remainingArity = Types.stageArity funcType
    ```

    as seen in the closure call paths around the papExtend generation  .
  - Leave `generateClosure`’s PAP creation arity as‑is.

**Invariants & tests:**

- `design_docs/invariants.csv`:
  - Update MONO_016 description to “closure params length equals stage arity”.
- `compiler/tests/Compiler/Generate/Monomorphize/WrapperCurriedCallsTest.elm`:
  - Check stage arity instead of `countTotalArity`.
- `compiler/tests/Compiler/Generate/CodeGen/PapExtendArity*.elm`:
  - Implement CGEN_052 based on per‑stage remaining arity (`arity - num_captured`) as described in §6.2.
- `TypeSubst.elm`:
  - Remove TLambda flattening in `applySubst` (see §2.1) .
  - Keep `extractParamTypes` as a flattening helper.

- `Specialize.elm`:
  - Keep `peelFunctionChain` as is .
  - Replace `specializeLambda` body with stage‑aware logic in §3.1, selecting:
    - **uncurried** `effectiveMonoType` for fully peelable lambda chains,
    - **curried** nested `effectiveMonoType` for wrappers.

**Closures / wrappers:**

- `Closure.elm`:
  - No semantic changes; `flattenFunctionType` still flattens for `ensureCallableTopLevel` and alias closures, which is correct even with nested `MFunction`s .

**MLIR Types:**

- `Types.elm`:
  - Add `stageParamTypes` and `stageArity` helpers and export them (§4) .

**MLIR Expr (PAP + closure calls):**

- `Expr.elm`:
  - In all places that set `remaining_arity` on `eco.papExtend` or indirect `eco.call`, change:

    ```elm
    remainingArity = Types.countTotalArity funcType
    ```

    to:

    ```elm
    remainingArity = Types.stageArity funcType
    ```

    as seen in the closure call paths around the papExtend generation  .
  - Leave `generateClosure`’s PAP creation arity as‑is.

**Invariants & tests:**

- `design_docs/invariants.csv`:
  - Update MONO_016 description to “closure params length equals stage arity”.
- `compiler/tests/Compiler/Generate/Monomorphize/WrapperCurriedCallsTest.elm`:
  - Check stage arity instead of `countTotalArity`.
- `compiler/tests/Compiler/Generate/CodeGen/PapExtendArity*.elm`:
  - Implement CGEN_052 based on per‑stage remaining arity (`arity - num_captured`) as described in §6.2.
- `TypeSubst.elm`:
  - Remove TLambda flattening in `applySubst` (see §2.1) .
  - Keep `extractParamTypes` as a flattening helper.

- `Specialize.elm`:
  - Keep `peelFunctionChain` as is .
  - Replace `specializeLambda` body with stage‑aware logic in §3.1, selecting:
    - **uncurried** `effectiveMonoType` for fully peelable lambda chains,
    - **curried** nested `effectiveMonoType` for wrappers.

**Closures / wrappers:**

- `Closure.elm`:
  - No semantic changes; `flattenFunctionType` still flattens for `ensureCallableTopLevel` and alias closures, which is correct even with nested `MFunction`s .

**MLIR Types:**

- `Types.elm`:
  - Add `stageParamTypes` and `stageArity` helpers and export them (§4) .

**MLIR Expr (PAP + closure calls):**

- `Expr.elm`:
  - In all places that set `remaining_arity` on `eco.papExtend` or indirect `eco.call`, change:

    ```elm
    remainingArity = Types.countTotalArity funcType
    ```

    to:

    ```elm
    remainingArity = Types.stageArity funcType
    ```

    as seen in the closure call paths around the papExtend generation  .
  - Leave `generateClosure`’s PAP creation arity as‑is.

**Invariants & tests:**

- `design_docs/invariants.csv`:
  - Update MONO_016 description to “closure params length equals stage arity”.
- `compiler/tests/Compiler/Generate/Monomorphize/WrapperCurriedCallsTest.elm`:
  - Check stage arity instead of `countTotalArity`.
- `compiler/tests/Compiler/Generate/CodeGen/PapExtendArity*.elm`:
  - Implement CGEN_052 based on per‑stage remaining arity (`arity - num_captured`) as described in §6.2.
- `TypeSubst.elm`:
  - Remove TLambda flattening in `applySubst` (see §2.1) .
  - Keep `extractParamTypes` as a flattening helper.

- `Specialize.elm`:
  - Keep `peelFunctionChain` as is .
  - Replace `specializeLambda` body with stage‑aware logic in §3.1, selecting:
    - **uncurried** `effectiveMonoType` for fully peelable lambda chains,
    - **curried** nested `effectiveMonoType` for wrappers.

**Closures / wrappers:**

- `Closure.elm`:
  - No semantic changes; `flattenFunctionType` still flattens for `ensureCallableTopLevel` and alias closures, which is correct even with nested `MFunction`s .

**MLIR Types:**

- `Types.elm`:
  - Add `stageParamTypes` and `stageArity` helpers and export them (§4) .

**MLIR Expr (PAP + closure calls):**

- `Expr.elm`:
  - In all places that set `remaining_arity` on `eco.papExtend` or indirect `eco.call`, change:

    ```elm
    remainingArity = Types.countTotalArity funcType
    ```

    to:

    ```elm
    remainingArity = Types.stageArity funcType
    ```

    as seen in the closure call paths around the papExtend generation  .
  - Leave `generateClosure`’s PAP creation arity as‑is.

**Invariants & tests:**

- `design_docs/invariants.csv`:
  - Update MONO_016 description to “closure params length equals stage arity”.
- `compiler/tests/Compiler/Generate/Monomorphize/WrapperCurriedCallsTest.elm`:
  - Check stage arity instead of `countTotalArity`.
- `compiler/tests/Compiler/Generate/CodeGen/PapExtendArity*.elm`:
  - Implement CGEN_052 based on per‑stage remaining arity (`arity - num_captured`) as described in §6.2.
---

With this design:
- Simple nested lambdas (`\x -> \y -> \z -> ...`) behave exactly as in your partial Option A implementation: **one uncurried stage**, flat type, flat params.
- Functions with visible staging boundaries (`let` / `case` wrappers) are **curried at Mono**:
  - Their MonoType is nested (`MFunction [x] (MFunction [y] ...)`),
  - Their first‑stage closure only has `[x]` params,
  - Further stages appear as separate closures.
- MLIR codegen bases PAP and closure arity on **stageArity**, not flattened total arity, so both uncurried and curried cases are handled correctly.
