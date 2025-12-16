## 0. High‑level goal recap

Current behavior:

- `TypedModule.addRecDefs` groups mutually recursive defs into a single `TOpt.Cycle` node, with:
    - `names : List Name`
    - `values : List (Name, TOpt.Expr)` for 0‑arg value defs
    - `functions : List TOpt.Def` for defs with args (tail‑optimized)
- Each original top‑level in the cycle has a `TOpt.Link` node pointing to the shared `Cycle` node.
- Monomorphization’s `specializeNode` sees `TOpt.Cycle` and calls `specializeCycle`, which:
    - Uses an *empty* substitution,
    - Produces `Mono.MonoCycle (List (Name, MonoExpr)) deps monoType`.
- MLIR backend’s `generateNode` translates `Mono.MonoCycle` via `generateCycle`, which:
    - Generates every member into a `MonoExpr` (functions become closures via `MonoClosure` → `eco.papCreate`),
    - Bundles them in an `eco.construct`,
    - Wraps that in a *nullary* `func.func` returning a record of all members.

Call sites, however, come through `TOpt.VarCycle` → `Mono.MonoVarGlobal` → `generateCall` and expect a *proper function* taking arguments, not a nullary thunk returning a bundle.  turn9file12

Goal:

- When specializing a cycle because some member `f` is needed at `MonoType T`, we:
    - Compute **one shared substitution** from `T` and `f`’s canonical type.
    - Use it to specialize **all** members in the SCC.
    - Emit **one `MonoTailFunc` (or `MonoDefine`) per function member**, and register a separate `SpecId` for each.
    - Return the node corresponding to `f` from `specializeNode`.
- No `MonoCycle` for function cycles; MLIR sees only ordinary `func.func`s with correct parameters.

---

## 1. Make `specializeCycle` aware of “which member was requested”

Right now `processWorklist` has the information but doesn’t pass it down:

- Work items: `WorkItem = SpecializeGlobal Mono.Global Mono.MonoType (Maybe Mono.LambdaId)`
- `processWorklist` loops, pops `SpecializeGlobal global monoType maybeLambda`, computes `specId`, and then:

  ```elm
  case Dict.get TOpt.toComparableGlobal toptGlobal state.toptNodes of
      Just toptNode ->
          let
              ( monoNode, stateAfterSpec ) =
                  specializeNode toptNode monoType maybeLambda stateWithId
  ```   

- `specializeNode` currently knows only `node`, `monoType`, `maybeLambda`, not which `Mono.Global` triggered the specialization.

**Change (extrapolated):**

Add the requested global to `specializeNode` (or to `MonoState`):

Option A1 – extend `specializeNode`’s signature:

- Change:

  ```elm
  specializeNode : TOpt.Node -> Mono.MonoType -> Maybe Mono.LambdaId -> MonoState -> ( Mono.MonoNode, MonoState )
  ```

  to:

  ```elm
  specializeNode :
      Mono.Global                -- requested global
      -> TOpt.Node
      -> Mono.MonoType
      -> Maybe Mono.LambdaId
      -> MonoState
      -> ( Mono.MonoNode, MonoState )
  ```

- Update `processWorklist`:

  ```elm
  let
      toptGlobal =
          monoGlobalToTOpt global
  in
  case Dict.get TOpt.toComparableGlobal toptGlobal state.toptNodes of
      Just toptNode ->
          let
              ( monoNode, stateAfterSpec ) =
                  specializeNode global toptNode monoType maybeLambda stateWithId
  ```

- All non‑cycle cases in `specializeNode` just ignore the new `global` argument.

Option A2 – store `currentGlobal` in `MonoState`:

- Add a field to `MonoState`:

  ```elm
  , currentGlobal : Maybe Mono.Global
  ```

- Right before calling `specializeNode` in `processWorklist`, set:

  ```elm
  let
      stateWithId =
          { state
              | registry = newRegistry
              , inProgress = EverySet.insert identity specId state.inProgress
              , worklist = rest
              , currentGlobal = Just global
          }
  ```

- After specialization, clear it:

  ```elm
  newState =
      { stateAfterSpec
          | nodes = Dict.insert identity specId monoNode stateAfterSpec.nodes
          , inProgress = EverySet.remove identity specId stateAfterSpec.inProgress
          , currentGlobal = Nothing
      }
  ```

- Inside `specializeCycle` you read `state.currentGlobal` to find the requested member.

Either way, you need `requestedName : Name` and `requestedCanonical : IO.Canonical` to match against `names` in the cycle and to build member `Mono.Global`s.

---

## 2. Rewrite `specializeCycle` to follow Option A

Current `specializeCycle` ignores the requested function and uses an empty substitution:

```elm
specializeCycle names values functions monoType state =
    let
        subst = Dict.empty
        ( monoValues, state1 ) =
            specializeValueDefs values subst state
        ( monoFunctions, state2 ) =
            specializeFuncDefs functions subst state1
        allDefs = monoValues ++ monoFunctions
        depIds = collectCycleDependencies allDefs
    in
    ( Mono.MonoCycle allDefs depIds monoType, state2 )
```

### 2.1. Compute a shared substitution for the cycle

You want:

- Find the function in `functions : List TOpt.Def` that corresponds to the *requested* name.
- Get its canonical function type.
- Unify that with `monoType` to build the substitution.

You already have:

- `names : List Name` listing all defs in the cycle (values + functions) in source order.
- For function members, `functions : List TOpt.Def`. In typed optimized IR:
    - `TOpt.Def region name expr type` – carries full `Can.Type` for the *definition expression*.
    - `TOpt.DefineTailFunc region argNames body deps type` on the `Node` side, but for cycles you store the original `Opt.Def` / tail defs in `functions`.

You also already have helpers:

- `buildFuncType : List (A.Located Name, Can.Type) -> Can.Type -> Can.Type` to turn arg/result types into a `Can.TLambda` chain (used for tail funcs).
- `unify : Can.Type -> Mono.MonoType -> Substitution` and `applySubst : Substitution -> Can.Type -> Mono.MonoType`.

**Plan for `specializeCycle`:**

Replace the empty‑subst logic with:

```elm
specializeCycle names values functions requestedMonoType state =
    let
        -- 1. Determine requested function name
        (requestedCanonical, requestedName) =
            case state.currentGlobal of
                Just (Mono.Global canonical name) ->
                    ( canonical, name )

                Nothing ->
                    -- fallback or crash: we really expect currentGlobal to be set
                    ( state.currentModule, List.head names |> Maybe.withDefault "_cycle" )

        -- 2. Find the TOpt.Def for that name in `functions`
        maybeRequestedDef =
            List.filter
                (\def ->
                    case def of
                        TOpt.Def _ name _ _ ->
                            name == requestedName

                        TOpt.TailDef _ name _ _ _ ->
                            name == requestedName
                )
                functions
                |> List.head

        -- 3. Get canonical function type for that def
        requestedCanType =
            case maybeRequestedDef of
                Just (TOpt.Def _ _ _ canType) ->
                    canType

                Just (TOpt.TailDef _ _ args _ returnType) ->
                    buildFuncType args returnType

                Nothing ->
                    -- Should not happen; maybe default to first function's type
                    ...

        -- 4. Build substitution from requested type and monoType
        subst =
            unify requestedCanType requestedMonoType

        -- 5. Specialize values and functions with this subst (see below)
    in
    ...
```

(Details of how you surface `currentGlobal` as in §1.)

### 2.2. Specialize value members as before (possibly with shared subst)

`specializeValueDefs` already walks `(Name, TOpt.Expr)` and calls `specializeExpr` for each with a substitution.

You can keep it, but now pass `subst` from above:

```elm
( monoValues, stateAfterValues ) =
    specializeValueDefs values subst state
```

These become `(Name, MonoExpr)` pairs that you may still want to bundle into a `MonoCycle` record (see §3). They are *not* turned into separate `MonoTailFunc`s.

### 2.3. Emit proper `MonoTailFunc` nodes for all function members

Right now `specializeFuncDefs` + `specializeCycleDef` produces **expressions**:

- `TOpt.Def` → just `(name, MonoExpr)` with applied types.
- `TOpt.TailDef` → `Mono.MonoClosure` expression (PAP, with lambda and captures) and treats that as a cycle member expression.

For Option A, you want *nodes* (like non‑cycle functions). You already have code for a non‑cycle tail func in `specializeNode`:

```elm
TOpt.DefineTailFunc _ args body _ returnType ->
    let
        funcType =
            buildFuncType args returnType

        subst =
            unify funcType monoType

        monoArgs =
            List.map (specializeArg subst) args

        ( monoBody, stateAfter ) =
            specializeExpr body subst state

        depIds =
            collectDependencies monoBody

        monoReturnType =
            applySubst subst returnType
    in
    ( Mono.MonoTailFunc monoArgs monoBody depIds monoReturnType, stateAfter )
```   

**Refactor (extrapolated):**

1. Extract a helper that, *given* a substitution and a `TOpt.Def`, builds a `Mono.MonoTailFunc` (or `Mono.MonoDefine`):

   ```elm
   specializeFuncNodeInCycle :
       Substitution
       -> TOpt.Def
       -> MonoState
       -> ( Mono.MonoNode, MonoState )
   specializeFuncNodeInCycle subst def state =
       case def of
           TOpt.Def region name expr canType ->
               -- treat as normal function: type is canType
               let
                   monoType =
                       applySubst subst canType

                   -- parameters were already converted into a TOpt.TrackedFunction
                   -- in TypedExpression; the body here is that closure.
                   ( monoExpr, state1 ) =
                       specializeExpr expr subst state

                   depIds =
                       collectDependencies monoExpr
               in
               ( Mono.MonoDefine monoExpr depIds monoType, state1 )

           TOpt.TailDef region name args body returnType ->
               let
                   funcType =
                       buildFuncType args returnType

                   monoFuncType =
                       applySubst subst funcType

                   monoArgs =
                       List.map (specializeArg subst) args

                   ( monoBody, state1 ) =
                       specializeExpr body subst state

                   depIds =
                       collectDependencies monoBody

                   monoReturnType =
                       applySubst subst returnType
               in
               ( Mono.MonoTailFunc monoArgs monoBody depIds monoReturnType, state1 )
   ```

   This is largely the same as the non‑cycle `DefineTailFunc` branch but reuses the **shared** `subst` instead of recomputing unification per member.

2. Allocate and register `SpecId`s for each function member of the cycle:

   In `specializeCycle`, after computing `subst` and specializing values:

   ```elm
   let
       (funcNodes, stateAfterFuncs) =
           List.foldl
               (\def (acc, st) ->
                   let
                       name =
                           case def of
                               TOpt.Def _ n _ _ -> n
                               TOpt.TailDef _ n _ _ _ -> n

                       -- Build the global for this member
                       memberGlobal =
                           Mono.Global requestedCanonical name

                       -- Compute member's mono type for registry key
                       memberCanType =
                           case def of
                               TOpt.Def _ _ _ canType -> canType
                               TOpt.TailDef _ _ args _ ret ->
                                   buildFuncType args ret

                       memberMonoType =
                           applySubst subst memberCanType

                       ( specId, newRegistry ) =
                           Mono.getOrCreateSpecId memberGlobal memberMonoType Nothing st.registry

                       ( monoNode, st1 ) =
                           specializeFuncNodeInCycle subst def { st | registry = newRegistry }

                       st2 =
                           { st1
                               | nodes = Dict.insert identity specId monoNode st1.nodes
                           }
                   in
                   ( (name, specId) :: acc, st2 )
               )
               ( [], stateAfterValues )
               functions
   in
   ...
   ```

    - This simultaneously:
        - Computes specialized type per member (`memberMonoType`),
        - Allocates a `SpecId` consistent with the global and monoType,
        - Specializes the body using the *shared* substitution,
        - Inserts the resulting node into `state.nodes`.

3. Select and return the node for the originally requested member:

    - Among `(name, specId)` pairs you collected, pick the one where `name == requestedName`.
    - Optionally assert you found it.
    - Look up the node from `stateAfterFuncs.nodes` and return it as `monoNode` from `specializeCycle`.

   Sketch:

   ```elm
   let
       maybeRequestedSpecId =
           List.filter (\(name, _) -> name == requestedName) funcNodes
               |> List.head
               |> Maybe.map Tuple.second
   in
   case maybeRequestedSpecId of
       Just requestedSpecId ->
           case Dict.get identity requestedSpecId stateAfterFuncs.nodes of
               Just requestedNode ->
                   -- Combine depIds if you still want a cycle-wide set
                   ( requestedNode, stateAfterFuncs )

               Nothing ->
                   -- impossible, but handle
                   ( Mono.MonoExtern requestedMonoType, stateAfterFuncs )

       Nothing ->
           -- No function matched requestedName; maybe this is a value cycle
           ...
   ```

4. Dependencies: You might still want to compute a cycle‑level `depIds` for debugging or analysis, but for correctness each `MonoTailFunc` already has its own `depIds`. `collectCycleDependencies` can remain for the value‑cycle path.

### 2.4. Value‑only cycles (optional)

If you want to keep the existing “bundle values in a record” behavior for cycles that contain only values:

- Detect the case `List.isEmpty functions` in `specializeCycle`.
- In that branch:
    - Keep the old `Mono.MonoCycle` behavior (just with maybe a better substitution).
    - Return `Mono.MonoCycle` as before.
- In all branches where `functions` is non‑empty and `requestedMonoType` is a function type (`Mono.MFunction`), follow the new Option A logic and *do not* return `Mono.MonoCycle`.

This preserves semantics for things like mutually recursive top‑level constants, while fixing function cycles.

---

## 3. Remove (or narrow) `MonoCycle` usage and the MLIR bundling

After the above changes, for *function cycles* you’ll no longer construct `Mono.MonoCycle` at all; you’ll insert multiple `MonoTailFunc` / `MonoDefine` nodes and return a single node for the requested member.

### 3.1. Update `Mono.MonoNode` and `generateNode`

`Mono.MonoNode` currently has a `MonoCycle` variant and `generateNode` routes that to `generateCycle` :

```elm
type MonoNode
    = MonoDefine MonoExpr (EverySet Int Int) MonoType
    | MonoTailFunc (List ( Name, MonoType )) MonoExpr (EverySet Int Int) MonoType
    | ...
    | MonoCycle (List ( Name, MonoExpr )) (EverySet Int Int) MonoType
```

MLIR side:

```elm
case node of
    Mono.MonoDefine ... -> ...
    Mono.MonoTailFunc ... -> ...
    ...
    Mono.MonoCycle definitions _ monoType ->
        generateCycle ctx funcName definitions monoType
```   

And `generateCycle` builds the nullary thunk and record:

```elm
generateCycle ctx funcName definitions monoType =
    -- Generate mutually recursive definitions
    -- For now, generate a thunk that creates a record of all the cycle definitions
    ...
    funcFunc ctx funcName [] (monoTypeToMlir monoType) region
```

**Change (extrapolated):**

- For *function* cycles, ensure `specializeCycle` never constructs `Mono.MonoCycle`, so this `generateCycle` path won’t be taken for `List.foldl`/friends. That alone is enough to fix your mismatch.
- If you decide you don’t need value cycles either, you can:
    - Remove `Mono.MonoCycle` from the AST,
    - Remove `generateCycle` and the corresponding branch in `generateNode`,
    - Remove `generateVarCycle` (see below).
- If you keep value‑cycle bundling, leave `MonoCycle` and `generateCycle` in place, but ensure they are used **only** when `functions` is empty.

### 3.2. Remove `MonoVarCycle` / `generateVarCycle` glue (now dead)

In the MLIR backend you still have:

```elm
generateVarCycle : Context -> IO.Canonical -> Name.Name -> Mono.MonoType -> ExprResult
generateVarCycle ctx home name monoType =
    let
        cycleName =
            canonicalToMLIRName home ++ "_$cycle_" ++ name

        callOp =
            ecoCallNamed ctx1 var cycleName [] (monoTypeToMlir monoType)
```   

But in monomorphization, `TOpt.VarCycle` is already lowered to `Mono.MonoVarGlobal` and a `SpecializeGlobal` work item; you never produce `Mono.MonoVarCycle`.

So:

- Confirm `Mono.MonoVarCycle` is unused in `Monomorphized.elm` (it’s defined but unused).
- Delete `MonoVarCycle` and `generateVarCycle`, or at least stop using them anywhere in the MLIR backend. This removes the old `$cycle_` naming scheme and leaves only the specId‑based `specIdToFuncName` path.

---

## 4. Keep call‑site behavior as is

The good news: call sites are already correct for Option A, you don’t need large changes there.

- Typed/optimized expressions use `TOpt.VarCycle` when referencing a cycle member.
- Monomorphization converts `TOpt.VarCycle` into:

  ```elm
  monoGlobal = Mono.Global canonical name
  ( specId, newRegistry ) =
      Mono.getOrCreateSpecId monoGlobal monoType Nothing state.registry
  workItem = SpecializeGlobal monoGlobal monoType Nothing
  ...
  ( Mono.MonoVarGlobal region specId monoType, newState )
  ```   

- Expression codegen for calls uses `Mono.MonoVarGlobal` and `generateCall`:

  ```elm
  Mono.MonoVarGlobal _ specId _ ->
      -- direct call to known specialization
      eco.call @funcName(%args...) ...
  ```   

- And `generateVarGlobal` for function‑typed globals builds a closure via `eco.papCreate` but that’s orthogonal to cycles.

Once `specId` for `List.foldl` maps to a `MonoTailFunc` node (not `MonoCycle`), MLIR will emit:

```mlir
func.func @Elm_List_foldl_$_4(%func: !eco.value, %acc: !eco.value, %list: !eco.value) -> !eco.value
```

and `generateCall` will emit an `eco.call` with three operands and matching function type, eliminating the LLVM “incorrect number of operands” error.

---

## 5. Testing / validation steps

Finally, a concrete validation plan:

1. **Unit tests for monomorphization:**
    - Write a small Elm module with:

      ```elm
      foldl : (a -> b -> b) -> b -> List a -> b
      foldl f acc list = case list of ... foldlHelper f (f x acc) xs ...
 
      foldlHelper : (a -> b -> b) -> b -> List a -> b
      foldlHelper f acc list = foldl f acc list
      ```

    - Run just the monomorphization pass (dump `MonoGraph`) and check:
        - You have distinct `MonoTailFunc` nodes for `foldl` and `foldlHelper` with the same concrete `MonoType`.
        - No `MonoCycle` node for those specIds.

2. **MLIR dump:**
    - Compile with `--output whatever.mlir` so you hit the Mono MLIR backend.
    - Inspect for:
        - `func.func @Elm_List_foldl_$_N(%..., %..., %...) -> !eco.value`
        - Direct `eco.call` to that function with 3 operands.
        - No `func.func` with zero args corresponding to `foldl` or `foldlHelper`.

3. **Regression tests for value cycles (if you keep them):**
    - For a simple value recursion like:

      ```elm
      ones : List Int
      ones = 1 :: ones
      ```

    - Decide whether you want bundling or not. If you keep `MonoCycle` for values, ensure:
        - `MonoCycle` is still emitted.
        - MLIR’s `generateCycle` emits a nullary `func.func` returning a record, and that call sites are consistent.
    - If you drop bundling entirely, adjust how `VarCycle` values are represented (may require rethinking value cycles beyond this plan).

---

This outlines the concrete edits:

- **Monomorphize.elm**:
    - Extend `MonoState` or `specializeNode` to track the *requested* `Mono.Global`.  turn9file1
    - Rewrite `specializeCycle` to:
        - Compute a shared `subst` via `unify` using the requested member’s canonical type and `monoType`.
        - Use `specializeValueDefs` for `values`.
        - Use new helper `specializeFuncNodeInCycle` + `getOrCreateSpecId` to emit and register `MonoTailFunc`/`MonoDefine` nodes for all `functions`.
        - Return the node for the requested member.

- **Monomorphized.elm**:
    - Optionally remove or narrow `Mono.MonoCycle` and `Mono.MonoVarCycle`.

- **MLIR.elm**:
    - Remove (or restrict) `generateCycle`.
    - Remove unused `generateVarCycle`.
    - Rely on `generateNode`’s `MonoTailFunc` branch for all function cycles.

All of this is consistent with your Option A design and fits the existing architecture of TypedOptimized → Mono → MLIR.

---

Type substitution for `TailDef` – how to reconstruct the function type?

You already have exactly the helper you need on the Mono side:

```elm
buildFuncType : List ( A.Located Name, Can.Type ) -> Can.Type -> Can.Type
buildFuncType args returnType =
    List.foldr
        (\( _, argType ) acc ->
            Can.TLambda argType acc
        )
        returnType
        args
``` 

This is the canonical way the compiler reconstructs a full function type from a `TailDef`’s arguments and result:

- For `TailDef region name args body returnType`,
    - `args : List (A.Located Name, Can.Type)` are the parameter types,
    - `returnType : Can.Type` is the final result type,
    - `buildFuncType args returnType` produces a `Can.Type` like `arg1 -> arg2 -> ... -> returnType`.

You can see this used in:

- `specializeNode` for non‑cycle `DefineTailFunc`:

  ```elm
  TOpt.DefineTailFunc _ args body _ returnType ->
      let
          funcType =
              buildFuncType args returnType
          subst =
              unify funcType monoType
          ...
  ``` 

- `specializeCycleDef` for `TOpt.TailDef` inside cycles:

  ```elm
  TOpt.TailDef _ name args body returnType ->
      let
          -- Build the full function type
          funcType =
              buildFuncType args returnType
          ...
  ``` 

So for Option A you should:

1. For the requested cycle member `TailDef name args body returnType`, compute:

   ```elm
   let
       funcType : Can.Type
       funcType =
           buildFuncType args returnType
   ```

2. Unify that with the requested `monoType`:

   ```elm
   let
       subst : Substitution
       subst =
           unify funcType monoType
   ```

3. Reuse `subst` for every other `TOpt.Def` / `TOpt.TailDef` in the cycle.

There isn’t extra hidden complexity here; all the “hard bits” (aliases, records, unions, etc.) are already handled inside `unify` and `applySubst`/`canTypeToMonoType` . The TypedOptimized side uses the parallel `buildFunctionType : List Can.Type -> Can.Type -> Can.Type` helper in several places to compute canonical function types from argument and result types, so this pattern is consistent across the pipeline .

So the answer: **yes, use `buildFuncType` on `(args, returnType)` to reconstruct the canonical function type for a `TailDef`, then unify**. No additional special handling is needed.

---

How to get types for value definitions in cycles?

In the typed optimized IR, cycle nodes look like:

```elm
TOpt.Cycle names values functions deps
    -- values    : List ( Name, TOpt.Expr )
    -- functions : List TOpt.Def
``` 

For **function** members you have type info in the `TOpt.Def` variants (`canType` or `returnType` + arg types), and you reconstruct the full function type as above.

For **value** members (`values : List (Name, TOpt.Expr)`), you don’t see a separate `Can.Type` in the pair, but the type is already embedded in `TOpt.Expr` itself:

- Typed expression constructors always carry a `Can.Type`. For example:

  ```elm
  TOpt.Chr region chr charType
  TOpt.Int region int intType
  TOpt.Tuple region optA optB optCs tupleType
  TOpt.TrackedRecord region optFields recordType
  ...
  ``` 

- TypedExpression uses `TOpt.typeOf` everywhere to recover the type of an expression; e.g. when building records, tuples, cases, etc.

On the monomorphization side, `specializeExpr` also takes a `Can.Type` for each expression node and runs `applySubst` on it inside the constructors (e.g. `TOpt.VarLocal name canType` → `Mono.MonoVarLocal name (applySubst subst canType)`) . That’s how value types get monomorphized.

So for value definitions in a cycle:

- You *don’t* need to look up their type from annotations or from `names` separately.
- The type is already attached to each `TOpt.Expr` in `values`.
- When you call `specializeValueDefs values subst state`, each expression is specialized with the **same shared substitution** you computed from the requested function’s type, and its `Can.Type` fields are converted to `Mono.MonoType` via `applySubst` .

If you later need the final monomorphic type of a value member (e.g. for bundling into a record), you can compute it from the resulting `Mono.MonoExpr` with `Mono.typeOf` (already used elsewhere in monomorphization, like for record layouts and field indices) .

So the answer to Q2:

- **Their types do not “inherit from context” at `specializeCycle` time.**  
  Types were fixed earlier during type checking + typed optimization and are carried inside `TOpt.Expr`.
- To specialize them, you just:
    - Pass the shared substitution into `specializeExpr` for each `(Name, TOpt.Expr)` in `values`.
    - Let `specializeExpr` apply that substitution to all embedded `Can.Type`s.
    - Optionally read back the resulting `MonoType` from the resulting `MonoExpr` using `Mono.typeOf` if you need it.

You don’t need extra lookups beyond the types already present in `TOpt.Expr`; the context you care about (the particular instantiation of type variables for the cycle) is exactly the shared `subst` you computed from the requested function.

