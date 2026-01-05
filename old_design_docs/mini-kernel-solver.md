Below is a full, corrected design for the **mini kernel solver**, written to be directly implementable against your current codebase. I’ll:

- Use your existing modules and types,
- Show the exact new code to add or change,
- And fold in all the decisions from the “unresolved questions” discussion.

I’ll structure it as:

1. Goals and invariants
2. Overview of where this runs in the pipeline
3. Extending `Compiler.Optimize.Typed.KernelTypes` (mini‑solver)
4. Using `kernelEnv` in `Typed.Expression` (VarKernel case)
5. Wiring `kernelEnv` through `Typed.Module.optimizeTyped`
6. Limitations and rationale (partial application, HO usage, polymorphism)

Where I show code, it’s Elm in the style of your existing files.

---

## 1. Goals and invariants

We want a **kernel type environment**:

```elm
type alias KernelTypeEnv =
    Dict ( String, String ) ( Name, Name ) Can.Type
```

(as in your current `Compiler.Optimize.Typed.KernelTypes` module)

This maps each kernel function `(home, name)` (e.g. `("Basics","sqrt")`) to a **canonical type** (`Can.Type`):

- Possibly polymorphic (e.g. `comparable -> comparable -> Order` for `compare`),
- Or monomorphic (e.g. `Float` for `e`, `Float -> Float` for `sqrt`).

**Constraints:**

- We do **not** change the HM solver or constraint generation:
    - `Can.VarKernel` stays `CTrue` in the main solver (no constraints).
- Kernel types must be derived **after solving**, using:
    - Top‑level annotations (`annotations`),
    - TypedCanonical (`TCan.Module`) + per‑node types (`ExprTypes`),
    - But **never** by feeding VarKernels into the main solver.

**Key decisions from the questions:**

- If a kernel has an annotated alias, **that alias is authoritative** (we never check usage against it).
- Usage‑based inference is only for kernels **without aliases**.
- We do not attempt to infer higher‑order kernel types from usages where the kernel is an argument (e.g. `List.map Elm.Kernel.Basics.negate ...`); those must have aliases.
- Error handling for “missing kernel type” is via `Utils.Crash.crash` (compiler bug), not a user error in `MResult`.
- We avoid polymorphic equality issues by never comparing alias types to usage types; for unaliased kernels we just take the **first** usage type we see.

---

## 2. Where this runs in the pipeline

Typed pipeline entry (from docs and code):

- `Compile.typeCheckTyped`:
    - Runs `constrainWithIds` + `Solve.runWithIds`,
    - Produces `annotations` and `TCan.Module` + `ExprTypes` (per‑node `Can.Type`) via `TCan.fromCanonical`.

- `Compile.typedOptimizeFromTyped`:
    - Calls `Typed.Module.optimizeTyped annotations exprTypes typedCanonical`.

- `Compiler.Optimize.Typed.Module.optimizeTyped`:
    - Receives `annotations`, `exprTypes`, `TCan.Module`, currently computes `kernelEnv` **from aliases only** via `KernelTypes.fromDecls annotations tData.decls`, then runs `addDecls` etc.

- `Compiler.Optimize.Typed.Expression.optimize`:
    - Receives `kernelEnv`, `annotations`, `exprTypes`, `cycle`, and a `TCan.Expr`,
    - Currently uses `tipe` from TypedCanonical (the solver‑inferred type) for most cases, and still uses `tipe` for `VarKernel`.

The mini‑solver will live in `Compiler.Optimize.Typed.KernelTypes` and will run **inside `optimizeTyped`**, after alias seeding and before expression optimization.

---

## 3. Extend `Compiler.Optimize.Typed.KernelTypes` (mini‑solver)

**File:** `Compiler/Optimize/Typed/KernelTypes.elm`

Current skeleton:

```elm
module Compiler.Optimize.Typed.KernelTypes exposing
    ( KernelTypeEnv
    , fromDecls
    )

import Compiler.AST.Canonical as Can
import Compiler.AST.TypedCanonical as TCan
import Compiler.Data.Name exposing (Name)
import Compiler.Reporting.Annotation as A
import Data.Map as Dict exposing (Dict)

type alias KernelTypeEnv =
    Dict ( String, String ) ( Name, Name ) Can.Type
```

We will:

1. Keep `fromDecls` as phase 1 (alias seeding),
2. Add helpers: `toComparable`, `lookup`, `hasEntry`, `insertFirstUsage`, `buildFunctionType`,
3. Add phase 2: `inferFromUsage : TCan.Decls -> ExprTypes -> KernelTypeEnv -> KernelTypeEnv`.

### 3.1 Helpers (lookup, toComparable, etc.)

You already have `toComparable` and `checkKernelAlias` implemented in the real file:

```elm
toComparable : ( Name, Name ) -> ( String, String )
toComparable ( a, b ) =
    ( a, b )
```

And `fromDecls` uses it:

```elm
checkKernelAlias annotations defName (A.At _ texpr) env =
    case texpr of
        TCan.TypedExpr { expr } ->
            case expr of
                Can.VarKernel home name ->
                    case Dict.get Basics.identity defName annotations of
                        Just (Can.Forall _ tipe) ->
                            Dict.insert toComparable ( home, name ) tipe env
                        ...
```

Add a `lookup` helper:

```elm
lookup : Name -> Name -> KernelTypeEnv -> Maybe Can.Type
lookup home name env =
    Dict.get toComparable ( home, name ) env
```

This wraps the `Dict.get` with your `toComparable` so callers don’t need to remember the key shape.

Also add a simple `hasEntry`:

```elm
hasEntry : Name -> Name -> KernelTypeEnv -> Bool
hasEntry home name env =
    case Dict.get toComparable ( home, name ) env of
        Just _ ->
            True

        Nothing ->
            False
```

And a one‑shot insert used for unaliased kernels:

```elm
insertFirstUsage : Name -> Name -> Can.Type -> KernelTypeEnv -> KernelTypeEnv
insertFirstUsage home name tipe env =
    if hasEntry home name env then
        env
    else
        Dict.insert toComparable ( home, name ) tipe env
```

Finally, add a local `buildFunctionType` helper (or import from a shared place if you like):

```elm
buildFunctionType : List Can.Type -> Can.Type -> Can.Type
buildFunctionType argTypes resultType =
    List.foldr Can.TLambda resultType argTypes
```

This matches the style you already use for building function types from arg/result lists in the typed optimizer.

### 3.2 Phase 1 (alias seeding) – already implemented

You already have a phase 1 that scans `TCan.Decls` for zero‑arg defs whose body is exactly `VarKernel`, and uses top‑level `annotations` to populate the map:

```elm
fromDecls : Dict String Name Can.Annotation -> TCan.Decls -> KernelTypeEnv
fromDecls annotations decls =
    fromDeclsHelp annotations decls Dict.empty

fromDeclsHelp : Dict String Name Can.Annotation -> TCan.Decls -> KernelTypeEnv -> KernelTypeEnv
fromDeclsHelp annotations decls env =
    case decls of
        TCan.Declare def rest ->
            fromDeclsHelp annotations rest (checkDef annotations def env)

        TCan.DeclareRec def defs rest ->
            let
                env1 = checkDef annotations def env
                env2 = List.foldl (\d e -> checkDef annotations d e) env1 defs
            in
            fromDeclsHelp annotations rest env2

        TCan.SaveTheEnvironment ->
            env

checkDef : Dict String Name Can.Annotation -> TCan.Def -> KernelTypeEnv -> KernelTypeEnv
checkDef annotations def env =
    case def of
        TCan.Def (A.At _ name) args body ->
            case args of
                [] ->
                    checkKernelAlias annotations name body env
                _ ->
                    env

        TCan.TypedDef (A.At _ name) _ typedArgs body _ ->
            case typedArgs of
                [] ->
                    checkKernelAlias annotations name body env
                _ ->
                    env
```

`checkKernelAlias` checks if the body is exactly `Can.VarKernel home name` and, if so, records the polymorphic type from the annotation.

We **do not change** this logic. Phase 1 remains the same.

### 3.3 Phase 2 (usage inference) – new

We add a new function:

```elm
inferFromUsage :
    TCan.Decls
    -> TCan.ExprTypes
    -> KernelTypeEnv
    -> KernelTypeEnv
```

Purpose:

- Walk all **typed** expressions in the module,
- For each **direct call** of a kernel function (where the call’s function is a `VarKernel`),
    - Use the TypedCanonical types of the call and its arguments to synthesize the **full function type**,
    - Insert it into `KernelTypeEnv` **only if** no alias entry exists yet.

Because `TCan.Expr` only wraps the **current** expression in `TypedExpr { expr, tipe }` and subexpressions are still `Can.Expr`, we need the `ExprTypes` map (node id → type) to re‑wrap subexpressions; we can reuse `TCan.toTypedExpr exprTypes` exactly as `Typed.Expression.optimize` does.

#### 3.3.1 Top‑level driver

In `KernelTypes.elm`:

```elm
inferFromUsage :
    TCan.Decls
    -> TCan.ExprTypes
    -> KernelTypeEnv
    -> KernelTypeEnv
inferFromUsage decls exprTypes initialEnv =
    let
        inferDef : TCan.Def -> KernelTypeEnv -> KernelTypeEnv
        inferDef def env =
            case def of
                TCan.Def _ _ body ->
                    inferExpr (TCan.toTypedExpr exprTypes body) exprTypes env

                TCan.TypedDef _ _ _ body _ ->
                    inferExpr (TCan.toTypedExpr exprTypes body) exprTypes env

        inferDecls : TCan.Decls -> KernelTypeEnv -> KernelTypeEnv
        inferDecls ds env =
            case ds of
                TCan.Declare def rest ->
                    inferDecls rest (inferDef def env)

                TCan.DeclareRec d ds rest ->
                    let
                        env1 =
                            inferDef d env

                        env2 =
                            List.foldl inferDef env1 ds
                    in
                    inferDecls rest env2

                TCan.SaveTheEnvironment ->
                    env
    in
    inferDecls decls initialEnv
```

Note: `TCan.toTypedExpr : ExprTypes -> Can.Expr -> TCan.Expr` already exists and is used elsewhere.

#### 3.3.2 Expression traversal

Define:

```elm
inferExpr :
    TCan.Expr
    -> TCan.ExprTypes
    -> KernelTypeEnv
    -> KernelTypeEnv
inferExpr (A.At _ texpr) exprTypes env =
    case texpr of
        TCan.TypedExpr { expr, tipe } ->
            case expr of
                -- Direct kernel call: Call (VarKernel home name) args
                Can.Call func args ->
                    let
                        typedFunc : TCan.Expr
                        typedFunc =
                            TCan.toTypedExpr exprTypes func

                        envAfterFunc =
                            inferExpr typedFunc exprTypes env

                        envAfterArgs =
                            List.foldl
                                (\arg acc ->
                                    inferExpr (TCan.toTypedExpr exprTypes arg) exprTypes acc
                                )
                                envAfterFunc
                                args
                    in
                    case typedFunc of
                        A.At _ (TCan.TypedExpr { expr = Can.VarKernel home name }) ->
                            let
                                argTypes : List Can.Type
                                argTypes =
                                    List.map
                                        (\arg ->
                                            let
                                                A.At _ (TCan.TypedExpr { tipe = argType }) =
                                                    TCan.toTypedExpr exprTypes arg
                                            in
                                            argType
                                        )
                                        args

                                callResultType : Can.Type
                                callResultType =
                                    tipe

                                candidateType : Can.Type
                                candidateType =
                                    buildFunctionType argTypes callResultType
                            in
                            -- Only insert if there is no alias entry:
                            insertFirstUsage home name candidateType envAfterArgs

                        _ ->
                            envAfterArgs

                -- Lambda: recurse into body
                Can.Lambda patterns body ->
                    let
                        env1 =
                            inferExpr (TCan.toTypedExpr exprTypes body) exprTypes env
                    in
                    env1

                -- If: recurse into all branches and final
                Can.If branches final ->
                    let
                        env1 =
                            List.foldl
                                (\( cond, thenExpr ) acc ->
                                    acc
                                        |> inferExpr (TCan.toTypedExpr exprTypes cond) exprTypes
                                        |> inferExpr (TCan.toTypedExpr exprTypes thenExpr) exprTypes
                                )
                                env
                                branches
                    in
                    inferExpr (TCan.toTypedExpr exprTypes final) exprTypes env1

                -- Case: recurse into scrutinee and each branch body
                Can.Case scrutinee branches ->
                    let
                        env1 =
                            inferExpr (TCan.toTypedExpr exprTypes scrutinee) exprTypes env

                        stepBranch (Can.CaseBranch _ branchExpr) acc =
                            inferExpr (TCan.toTypedExpr exprTypes branchExpr) exprTypes acc
                    in
                    List.foldl stepBranch env1 branches

                -- Let: recurse into body and rhs
                Can.Let def body ->
                    let
                        env1 =
                            inferExpr (TCan.toTypedExpr exprTypes body) exprTypes env
                    in
                    inferDefExpr def exprTypes env1

                -- LetRec: recurse into body and each def
                Can.LetRec defs body ->
                    let
                        env1 =
                            inferExpr (TCan.toTypedExpr exprTypes body) exprTypes env
                    in
                    List.foldl
                        (\d acc -> inferDefExpr d exprTypes acc)
                        env1
                        defs

                -- LetDestruct: recurse into bound expr and body
                Can.LetDestruct _ bound body ->
                    inferExpr (TCan.toTypedExpr exprTypes bound) exprTypes env
                        |> inferExpr (TCan.toTypedExpr exprTypes body) exprTypes

                -- List: recurse into elements
                Can.List entries ->
                    List.foldl
                        (\e acc -> inferExpr (TCan.toTypedExpr exprTypes e) exprTypes acc)
                        env
                        entries

                -- Negate: recurse into subexpr
                Can.Negate sub ->
                    inferExpr (TCan.toTypedExpr exprTypes sub) exprTypes env

                -- Binop: recurse into left and right
                Can.Binop _ _ _ _ left right ->
                    inferExpr (TCan.toTypedExpr exprTypes left) exprTypes env
                        |> inferExpr (TCan.toTypedExpr exprTypes right) exprTypes

                -- Record: recurse into all field exprs
                Can.Record fields ->
                    Dict.values A.compareLocated fields
                        |> List.foldl
                            (\fieldExpr acc ->
                                inferExpr (TCan.toTypedExpr exprTypes fieldExpr) exprTypes acc
                            )
                            env

                -- Update: recurse into record and all field updates
                Can.Update record fields ->
                    let
                        env1 =
                            inferExpr (TCan.toTypedExpr exprTypes record) exprTypes env
                    in
                    Dict.toList A.compareLocated fields
                        |> List.foldl
                            (\( _, Can.FieldUpdate _ e ) acc ->
                                inferExpr (TCan.toTypedExpr exprTypes e) exprTypes acc
                            )
                            env1

                -- Accessor: `.field` has no subexpr
                Can.Accessor _ ->
                    env

                -- Access: recurse into record expression
                Can.Access record _ ->
                    inferExpr (TCan.toTypedExpr exprTypes record) exprTypes env

                -- Tuple: recurse into all components
                Can.Tuple a b cs ->
                    inferExpr (TCan.toTypedExpr exprTypes a) exprTypes env
                        |> inferExpr (TCan.toTypedExpr exprTypes b) exprTypes
                        |> \acc ->
                            List.foldl
                                (\e acc_ -> inferExpr (TCan.toTypedExpr exprTypes e) exprTypes acc_)
                                acc
                                cs

                -- Shader: ignore
                Can.Shader _ _ ->
                    env

                -- Leaves: vars, literals, kernels, ctors, etc. — no recursion
                Can.VarLocal _ ->
                    env

                Can.VarTopLevel _ _ ->
                    env

                Can.VarKernel _ _ ->
                    -- bare kernel usage; we cannot infer HO types reliably
                    env

                Can.VarForeign _ _ _ ->
                    env

                Can.VarCtor _ _ _ _ _ ->
                    env

                Can.VarDebug _ _ _ ->
                    env

                Can.VarOperator _ _ _ _ ->
                    env

                Can.Chr _ ->
                    env

                Can.Str _ ->
                    env

                Can.Int _ ->
                    env

                Can.Float _ ->
                    env

                Can.Unit ->
                    env


inferDefExpr :
    Can.Def
    -> TCan.ExprTypes
    -> KernelTypeEnv
    -> KernelTypeEnv
inferDefExpr def exprTypes env =
    case def of
        Can.Def _ _ body ->
            inferExpr (TCan.toTypedExpr exprTypes body) exprTypes env

        Can.TypedDef _ _ _ body _ ->
            inferExpr (TCan.toTypedExpr exprTypes body) exprTypes env
```

**Important behavioral points:**

- We **only** infer from calls where `func` is a `VarKernel`, i.e. `Call (VarKernel home name) args`.
- We reconstruct the **full function type** from:
    - `argTypes` (types of arguments),
    - `callResultType` (type of the call expression itself),
    - via `buildFunctionType argTypes callResultType`.

Examples:

- `Elm.Kernel.Basics.log number` where `log : Float -> Float`:

    - `argTypes = [ Float ]`, `callResultType = Float`.
    - `candidateType = Float -> Float`.

- Partial application `Elm.Kernel.Basics.add 1` where `add : Int -> Int -> Int`:

    - TypedCanonical type for the call is `Int -> Int` (function).
    - `argTypes = [ Int ]`, `callResultType = Int -> Int`.
    - `candidateType = Int -> (Int -> Int)` = full `Int -> Int -> Int`.

- We **never** try to infer from `VarKernel` used as an argument (`List.map Elm.Kernel.Basics.negate ...`); for those, we rely on alias types.

**Crucially**, we only call `insertFirstUsage` to add an entry **if** the key is not already present. This is how we:

- Avoid comparing alias types (polymorphic) to usage types (monomorphic) and the “comparable vs Int” problem.
- Avoid any need for alpha‑equivalent type comparison; we just take the first candidate.

---

## 4. Use `kernelEnv` in `Typed.Expression` (VarKernel case)

**File:** `Compiler/Optimize/Typed/Expression.elm`

Current:

```elm
Can.VarKernel home name ->
    -- `tipe` is the solver-inferred type for this kernel expression
    Names.registerKernel home (TOpt.VarKernel region home name tipe)
```

Here `tipe` is the unconstrained solver variable’s `Can.Type` for the VarKernel node, which is not meaningful.

Change it to:

```elm
Can.VarKernel home name ->
    let
        kernelType : Can.Type
        kernelType =
            case KernelTypes.lookup home name kernelEnv of
                Just t ->
                    t

                Nothing ->
                    Utils.Crash.crash "Typed.Expression.optimizeExpr"
                        ("Missing kernel type for "
                            ++ Name.toChars home
                            ++ "."
                            ++ Name.toChars name
                        )
    in
    Names.registerKernel home (TOpt.VarKernel region home name kernelType)
```

Notes:

- `kernelEnv` is threaded into `optimize` and `optimizeExpr` already.
- If `lookup` returns `Nothing`, it means:
    - No alias (`fromDecls`) and
    - No direct call usage (`inferFromUsage`),
    - Yet we still see a `VarKernel` (e.g. only used higher‑order without alias).
- That should be treated as an **internal compiler bug / unsupported shape**, hence `Utils.Crash.crash`, not a user‑visible error.

All other cases in `optimizeExpr` continue using `tipe` from TypedCanonical, which is correct for locals, globals, ctors, etc.

---

## 5. Wire `kernelEnv` through `Typed.Module.optimizeTyped`

**File:** `Compiler/Optimize/Typed/Module.elm`

Current `optimizeTyped`:

```elm
optimizeTyped : Annotations -> ExprTypes -> TCan.Module -> MResult i (List W.Warning) TOpt.LocalGraph
optimizeTyped annotations exprTypes (TCan.Module tData) =
    let
        -- Build kernel function type environment from declarations
        kernelEnv : KernelTypes.KernelTypeEnv
        kernelEnv =
            KernelTypes.fromDecls annotations tData.decls
    in
    TOpt.LocalGraph
        { main = Nothing
        , nodes = Dict.empty
        , fields = Dict.empty
        , annotations = annotations
        }
        |> addAliases tData.name annotations tData.aliases
        |> addUnions tData.name annotations tData.unions
        |> addEffects tData.name annotations tData.effects
        |> addDecls tData.name annotations exprTypes kernelEnv tData.decls
```

Update it to incorporate phase 2:

```elm
optimizeTyped : Annotations -> ExprTypes -> TCan.Module -> MResult i (List W.Warning) TOpt.LocalGraph
optimizeTyped annotations exprTypes (TCan.Module tData) =
    let
        -- Phase 1: alias-based kernel types
        aliasEnv : KernelTypes.KernelTypeEnv
        aliasEnv =
            KernelTypes.fromDecls annotations tData.decls

        -- Phase 2: usage-based inference for unaliased kernels
        kernelEnv : KernelTypes.KernelTypeEnv
        kernelEnv =
            KernelTypes.inferFromUsage tData.decls exprTypes aliasEnv
    in
    TOpt.LocalGraph
        { main = Nothing
        , nodes = Dict.empty
        , fields = Dict.empty
        , annotations = annotations
        }
        |> addAliases tData.name annotations tData.aliases
        |> addUnions tData.name annotations tData.unions
        |> addEffects tData.name annotations tData.effects
        |> addDecls tData.name annotations exprTypes kernelEnv tData.decls
```

The rest of `Typed.Module` already threads `kernelEnv` correctly into `addDecls`, `addDef`, `addRecDefs`, and all calls into `Typed.Expression.optimize` / tail‑call helpers.

---

## 6. Limitations and rationale (tying back to the questions)

### 6.1 Polymorphic kernels (compare)

Example:

```elm
compare : comparable -> comparable -> Order
compare =
  Elm.Kernel.Utils.compare
```

- `fromDecls` sees a zero‑arg alias for `VarKernel "Utils" "compare"`.
- It records the **full polymorphic scheme** (with `TVar "comparable"`) as the kernel type.
- `inferFromUsage` checks `hasEntry` before inserting, so all usages (e.g. `compare 1 2`, `compare "a" "b"`) do **not** affect `kernelEnv`.
- Monomorphization uses that polymorphic `Can.Type` (`comparable -> comparable -> Order`) when specializing calls.

Thus we avoid the “comparable vs Int” equality problem entirely.

### 6.2 `TCan.toTypedExpr` existence

You **already have**:

```elm
toTypedExpr : Dict Int Can.Type -> Can.Expr -> Expr
```

in `Compiler.AST.TypedCanonical`, used to attach solver‑inferred `Can.Type` to each canonical expression using its `id`.

We reuse it in `inferFromUsage` exactly as `Typed.Expression.optimize` does today for all subexpressions.

### 6.3 Partial application

The call node’s `tipe` in TypedCanonical is the **post‑application** type:

- For `Elm.Kernel.Basics.add 1` with `add : Int -> Int -> Int`, the call node has `tipe = Int -> Int`.
- With `argTypes = [Int]` and `callResultType = Int -> Int`, `buildFunctionType` reconstructs `Int -> Int -> Int`.

So partial application is automatically handled correctly by the `buildFunctionType argTypes callResultType` logic in `inferFromUsage`.

### 6.4 Bare kernel references / higher‑order uses

Example:

```elm
List.map Elm.Kernel.Basics.negate [ 1, 2, 3 ]
```

Here the kernel appears as an **argument**, not the call’s function. Our mini‑solver does **not** try to infer types from that:

- For the VarKernel node itself, the solver variable is unconstrained (because constraints for `VarKernel` are `CTrue`), so TypedCanonical’s `tipe` for that node is just a fresh TVar, not `Int -> Int`.
- Only the context (the `List.map` type) knows the expected function type, but we purposely do not route that back into the VarKernel’s variable.

**Policy**:

- Higher‑order kernel uses must have an alias with annotation (`fromDecls` phase 1).
- `inferFromUsage` only infers types from **direct calls** where the function is a `VarKernel`.

If a kernel is only ever used higher‑order and has no alias, `lookup` will fail and you’ll see the `Utils.Crash.crash` in `Typed.Expression.optimizeExpr`, which is acceptable as an internal invariant violation.

### 6.5 Error handling

We use `Utils.Crash.crash` only in one place:

- In `Typed.Expression.optimizeExpr`, when `VarKernel` is encountered but `KernelTypes.lookup` returns `Nothing`. This indicates:
    - Neither `fromDecls` nor `inferFromUsage` produced a type,
    - Yet we are attempting to optimize a VarKernel; it’s a compiler bug / unsupported pattern.

All other paths are total. There is no user‑visible error in `MResult` for the mini‑solver.

### 6.6 Type variable names / alpha‑equivalence

Because we do not compare alias types to usage types, and for unaliased kernels we only insert the first observed usage type and never compare subsequent ones, we avoid all alpha‑equivalence problems.

If you ever want a debug‑time consistency check for unaliased kernels, you could add:

- A unifier on `Can.Type` that renames TVars away (alpha‑equivalence),
- Or reuse the HM solver’s `srcTypeToVar` + `Unify` + `toCanType` machinery for that subset.

But the minimal, robust design does **not** need that.

---

## 7. Summary

To implement the mini kernel solver:

1. **Extend `Compiler.Optimize.Typed.KernelTypes`**:
    - Keep `KernelTypeEnv` and `fromDecls` as they are (phase 1 alias seeding).
    - Add helpers: `lookup`, `hasEntry`, `insertFirstUsage`, `buildFunctionType`.
    - Add `inferFromUsage : TCan.Decls -> ExprTypes -> KernelTypeEnv -> KernelTypeEnv` with the traversal shown above, inferring only from `Call (VarKernel ...) args` and inserting only when no alias entry exists.

2. **Modify `Typed.Module.optimizeTyped`** to:
    - Compute `aliasEnv = fromDecls annotations tData.decls`,
    - Compute `kernelEnv = inferFromUsage tData.decls exprTypes aliasEnv`,
    - Pass `kernelEnv` into `addDecls` (already wired through).

3. **Modify `Typed.Expression.optimizeExpr`’s `VarKernel` case** to:
    - Use `KernelTypes.lookup home name kernelEnv` to get `kernelType`,
    - Crash via `Utils.Crash.crash` if missing,
    - Build `TOpt.VarKernel region home name kernelType`.

With these changes:

- Kernels with annotated aliases (polymorphic or monomorphic) get their types directly from those annotations.
- Unaliased kernels used in direct calls get types inferred from usage.
- Partial application is handled correctly.
- Higher‑order uses require annotations.
- Monomorphization sees real function types on `TOpt.VarKernel` and can specialize them using the existing `unifyFuncCall` logic.

