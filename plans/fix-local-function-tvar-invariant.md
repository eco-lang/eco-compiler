# Fix Local Function tvar Invariant (TOPT_FN_TVAR_001)

## Problem

For every function-typed expression or definition in TypedOptimized, `meta.tvar` must be
the solver variable for the **full function type**, not the body/return type. This invariant
is currently violated for local functions:

1. **Local let-rec functions** (critical — causes crashes):
   `optimizePotentialTailCallDef` passes an empty `annotationVars` map, so
   `optimizePotentialTailCall` falls back to `bodyTvar` for `nodeTvar`, and uses that as
   the `TOpt.TailDef`/`TrackedFunction` meta tvar.
   (Expression.elm:887, 890)

2. **Non-recursive let-bound functions** (invariant violation, not currently crashing):
   `optimizeDefHelp` builds `TOpt.TrackedFunction` with `{ tipe = funcType, tvar = defBodyTvar }`
   where `defBodyTvar` is the body's tvar (return type), not the function's tvar.
   (Expression.elm:858-859)

The crash path: MonoDirect's `resolveType` sees a return-type tvar instead of a
function-type tvar, so `flattenFunctionType` yields `[]` params, and `specializePath`
cannot find parameter names in VarEnv.

## Scope

The **crash** only affects single-def `LetRec` → `TailDef`:

- `TailDef` is only constructed in `optimizePotentialTailCall` for `Can.LetRec` with a
  single def where `hasTailCall name obody` is true.
- Non-recursive `let` bindings go through `optimizeDef`/`optimizeDefHelp` and produce
  `TOpt.Def` with `TrackedFunction` but never `TailDef`. They don't flow into the
  decision-tree machinery that uses `specializePath`.
- Multi-def `LetRec` (including indirect mutual recursion) goes through the general
  `optimizeDef` pipeline with no `TailDef`.

However, we fix **both** cases for full invariant coverage.

## Approach

Recover the binder's full function-type solver variable by scanning canonical expressions
for `Can.VarLocal name` occurrences. Each use of a bound function `f` carries a tvar for
the full function type. No changes to MonoDirect are needed.

- For **let-rec** (single-def): scan the RHS body for self-calls (guaranteed to find one).
- For **non-recursive let**: scan the continuation body for uses of the bound name.
- For **multi-def let-rec** (defensive): scan the RHS body for self-calls; falls back to
  `defBodyTvar` for defs that only recurse indirectly.

All changes are in **`compiler/src/Compiler/LocalOpt/Typed/Expression.elm`**.

---

## Step 1: Add `findVarLocalTvar` helper

**Location**: After `peelFunctionType` (around line 86), before `-- ====== OPTIMIZE ======`.

Add a helper that traverses a `Can.Expr` tree looking for `Can.VarLocal targetName` and
returns the first matching tvar from `exprVars`.

**Design choice**: The original spec proposes scanning `TCan.Expr`, but `Can.Expr_`
sub-expressions are `Can.Expr` (not `TCan.Expr`), so recursive calls wouldn't type-check.
Instead, operate directly on `Can.Expr` and look up tvars from the `exprVars` array by
expression ID.

**Shadow-awareness**: The compiler's canonicalization phase forbids name shadowing, so
all `VarLocal targetName` occurrences within a scope necessarily refer to the same
binding. No special shadow-tracking logic is needed in the traversal.

```elm
{-| Find the solver tvar for a local variable by scanning a Canonical
expression for `VarLocal name` occurrences.

Used to recover the *function* type variable for locally-defined functions:
  * LetRec single-def: scan the RHS body for self-calls.
  * Non-recursive let: scan the continuation body for uses of the bound name.

Returns the tvar from the first `VarLocal name` found, which is the binder's
solver variable for the full (possibly polymorphic) function type.

Note: canonicalization forbids name shadowing, so all VarLocal occurrences
of targetName within a scope refer to the same binding.
-}
findVarLocalTvar : Name -> ExprVars -> Can.Expr -> Maybe IO.Variable
findVarLocalTvar targetName exprVars (A.At _ info) =
    case info.node of
        Can.VarLocal name ->
            if name == targetName then
                Array.get info.id exprVars |> Maybe.andThen identity
            else
                Nothing

        -- Leaf nodes: no sub-expressions to search
        Can.VarTopLevel _ _ -> Nothing
        Can.VarKernel _ _ -> Nothing
        Can.VarForeign _ _ _ -> Nothing
        Can.VarCtor _ _ _ _ _ -> Nothing
        Can.VarDebug _ _ _ -> Nothing
        Can.VarOperator _ _ _ _ -> Nothing
        Can.Chr _ -> Nothing
        Can.Str _ -> Nothing
        Can.Int _ -> Nothing
        Can.Float _ -> Nothing
        Can.Accessor _ -> Nothing
        Can.Unit -> Nothing
        Can.Shader _ _ -> Nothing

        -- Single sub-expression
        Can.Negate e ->
            findVarLocalTvar targetName exprVars e

        Can.Lambda _ body ->
            findVarLocalTvar targetName exprVars body

        Can.Access recordExpr _ ->
            findVarLocalTvar targetName exprVars recordExpr

        -- Two sub-expressions
        Can.Binop _ _ _ _ left right ->
            firstJust2 targetName exprVars left right

        -- Function call
        Can.Call func args ->
            case findVarLocalTvar targetName exprVars func of
                Just v -> Just v
                Nothing -> firstJustList targetName exprVars args

        -- Lists, tuples, records
        Can.List entries ->
            firstJustList targetName exprVars entries

        Can.Tuple a b rest ->
            case findVarLocalTvar targetName exprVars a of
                Just v -> Just v
                Nothing ->
                    case findVarLocalTvar targetName exprVars b of
                        Just v -> Just v
                        Nothing -> firstJustList targetName exprVars rest

        Can.Record fields ->
            Dict.values fields
                |> firstJustList targetName exprVars

        Can.Update _ fields ->
            Data.Map.values fields
                |> firstJustList targetName exprVars

        -- Control flow
        Can.If branches final ->
            let
                tryBranch ( cond, branchExpr ) =
                    case findVarLocalTvar targetName exprVars cond of
                        Just v -> Just v
                        Nothing -> findVarLocalTvar targetName exprVars branchExpr
            in
            case firstJustMap tryBranch branches of
                Just v -> Just v
                Nothing -> findVarLocalTvar targetName exprVars final

        Can.Case scrutinee branches ->
            case findVarLocalTvar targetName exprVars scrutinee of
                Just v -> Just v
                Nothing ->
                    firstJustMap
                        (\(Can.CaseBranch _ branchExpr) ->
                            findVarLocalTvar targetName exprVars branchExpr
                        )
                        branches

        -- Let expressions (no shadow concern — canonicalization forbids shadowing)
        Can.Let def body ->
            case findVarLocalTvarInDef targetName exprVars def of
                Just v -> Just v
                Nothing -> findVarLocalTvar targetName exprVars body

        Can.LetRec defs body ->
            case firstJustMap (findVarLocalTvarInDef targetName exprVars) defs of
                Just v -> Just v
                Nothing -> findVarLocalTvar targetName exprVars body

        Can.LetDestruct _ boundExpr body ->
            firstJust2 targetName exprVars boundExpr body


findVarLocalTvarInDef : Name -> ExprVars -> Can.Def -> Maybe IO.Variable
findVarLocalTvarInDef targetName exprVars def =
    case def of
        Can.Def _ _ body ->
            findVarLocalTvar targetName exprVars body

        Can.TypedDef _ _ _ body _ ->
            findVarLocalTvar targetName exprVars body


{-| Helper: return first Just from two expressions -}
firstJust2 : Name -> ExprVars -> Can.Expr -> Can.Expr -> Maybe IO.Variable
firstJust2 targetName exprVars a b =
    case findVarLocalTvar targetName exprVars a of
        Just v -> Just v
        Nothing -> findVarLocalTvar targetName exprVars b


{-| Helper: return first Just from a list of expressions -}
firstJustList : Name -> ExprVars -> List Can.Expr -> Maybe IO.Variable
firstJustList targetName exprVars exprs =
    case exprs of
        [] -> Nothing
        e :: rest ->
            case findVarLocalTvar targetName exprVars e of
                Just v -> Just v
                Nothing -> firstJustList targetName exprVars rest


{-| Helper: return first Just from mapping over a list -}
firstJustMap : (a -> Maybe IO.Variable) -> List a -> Maybe IO.Variable
firstJustMap f list =
    case list of
        [] -> Nothing
        x :: rest ->
            case f x of
                Just v -> Just v
                Nothing -> firstJustMap f rest
```

**Pre-implementation checks** (do these before writing code):
- Read `Can.Expr_` type definition in `compiler/src/Compiler/AST/Canonical.elm` (~line 121)
  and verify all variants are covered exhaustively.
- Check `Can.Update` field type — is it `Data.Map.Dict ... Can.Expr` or a wrapped type
  like `A.Located Can.Expr`? Also check `Can.Record`.
- Verify `Data.Map.values` is available (check `Data.Map` module or use `Data.Map.foldl`
  as alternative).
- Verify `Dict.values` is available for `Can.Record` fields.

---

## Step 2: Fix `optimizePotentialTailCallDef` (local let-rec functions)

**This is the critical fix.** This is the only code path that produces `TailDef`, and
it's the one causing MonoDirect crashes.

**Location**: Expression.elm, lines 878-890.

**Current code**:
```elm
optimizePotentialTailCallDef kernelEnv annotations exprTypes exprVars home cycle def =
    case def of
        Can.Def (A.At region name) args body ->
            let
                ( _, defType ) =
                    getDefNameAndType exprTypes def
            in
            -- Local LetRec defs won't be in module-level annotationVars, so pass empty
            optimizePotentialTailCall ... Data.Map.empty

        Can.TypedDef (A.At region name) _ typedArgs body defType ->
            optimizePotentialTailCall ... Data.Map.empty
```

**Change**: Build a local `annotationVars` singleton map for the def name by scanning the
body for `VarLocal name` and recovering the function tvar.

```elm
optimizePotentialTailCallDef kernelEnv annotations exprTypes exprVars home cycle def =
    case def of
        Can.Def (A.At region name) args body ->
            let
                ( _, defType ) =
                    getDefNameAndType exprTypes def

                localAnnotationVars =
                    case findVarLocalTvar name exprVars body of
                        Just v ->
                            Data.Map.singleton identity name v

                        Nothing ->
                            Data.Map.empty
            in
            optimizePotentialTailCall kernelEnv annotations exprTypes exprVars home cycle
                region name args
                (TCanBuild.toTypedExpr exprTypes exprVars body)
                defType localAnnotationVars

        Can.TypedDef (A.At region name) _ typedArgs body defType ->
            let
                localAnnotationVars =
                    case findVarLocalTvar name exprVars body of
                        Just v ->
                            Data.Map.singleton identity name v

                        Nothing ->
                            Data.Map.empty
            in
            optimizePotentialTailCall kernelEnv annotations exprTypes exprVars home cycle
                region name (List.map Tuple.first typedArgs)
                (TCanBuild.toTypedExpr exprTypes exprVars body)
                defType localAnnotationVars
```

**Why this works**: Inside `optimizePotentialTailCall`, the existing logic:
```elm
nodeTvar =
    case Data.Map.get identity name annotationVars of
        Just var -> Just var
        Nothing -> bodyTvar
```
will now find `var` in our singleton map, giving `nodeTvar` the function-type tvar.
This `nodeTvar` flows into both `TOpt.TailDef` and `TOpt.TrackedFunction` metas.

Since `optimizePotentialTailCallDef` is only called for single-def `LetRec` (where the
function is directly self-recursive), the scan of the RHS body is **guaranteed** to find
at least one `VarLocal name` — the recursive call that makes it a LetRec.

---

## Step 3: Extend `optimizeDef`/`optimizeDefHelp` with `defNodeTvar` parameter

**This extends the invariant to non-recursive `let` and multi-def `LetRec`.**

### 3A. Extend signatures

**Current signatures** (Expression.elm:764, 784):
```elm
optimizeDef :
    KernelTypes.KernelTypeEnv -> Annotations -> ExprTypes -> ExprVars
    -> IO.Canonical -> Cycle -> Can.Def -> Can.Type
    -> TOpt.Expr -> Names.Tracker TOpt.Expr

optimizeDefHelp :
    KernelTypes.KernelTypeEnv -> Annotations -> ExprTypes -> ExprVars
    -> IO.Canonical -> Cycle -> A.Region -> Name -> List Can.Pattern
    -> Can.Expr -> Can.Type
    -> TOpt.Expr -> Names.Tracker TOpt.Expr
```

**Add `defNodeTvar : Maybe IO.Variable`** parameter to both, placed after `Can.Type`
(the `resultType`) and before `TOpt.Expr` (the continuation):

```elm
optimizeDef :
    KernelTypes.KernelTypeEnv -> Annotations -> ExprTypes -> ExprVars
    -> IO.Canonical -> Cycle -> Can.Def -> Can.Type
    -> Maybe IO.Variable    -- NEW: defNodeTvar
    -> TOpt.Expr -> Names.Tracker TOpt.Expr
optimizeDef kernelEnv annotations exprTypes exprVars home cycle def resultType defNodeTvar body =
    case def of
        Can.Def (A.At region name) args expr ->
            optimizeDefHelp kernelEnv annotations exprTypes exprVars home cycle
                region name args expr resultType defNodeTvar body

        Can.TypedDef (A.At region name) _ typedArgs expr _ ->
            optimizeDefHelp kernelEnv annotations exprTypes exprVars home cycle
                region name (List.map Tuple.first typedArgs) expr resultType defNodeTvar body

optimizeDefHelp :
    KernelTypes.KernelTypeEnv -> Annotations -> ExprTypes -> ExprVars
    -> IO.Canonical -> Cycle -> A.Region -> Name -> List Can.Pattern
    -> Can.Expr -> Can.Type
    -> Maybe IO.Variable    -- NEW: defNodeTvar
    -> TOpt.Expr -> Names.Tracker TOpt.Expr
```

### 3B. Use `defNodeTvar` inside `optimizeDefHelp`

**Current code** (lines 799-809, 858-859):
```elm
    let
        defBodyTvar : Maybe IO.Variable
        defBodyTvar =
            Array.get (A.toValue expr).id exprVars |> Maybe.andThen identity

        letTvar : Maybe IO.Variable
        letTvar =
            TOpt.tvarOf body
    in
    ...
            ofunc =
                TOpt.TrackedFunction argNamesWithTypes wrappedBody
                    { tipe = funcType, tvar = defBodyTvar }
```

**Change**: Compute `funcTvar` with a three-level fallback:
1. `defNodeTvar` if provided by caller (continuation-body scan for non-recursive let)
2. `findVarLocalTvar name exprVars expr` (self-call scan for multi-def LetRec)
3. `defBodyTvar` (unchanged fallback for unused functions / indirect recursion)

```elm
    let
        defBodyTvar : Maybe IO.Variable
        defBodyTvar =
            Array.get (A.toValue expr).id exprVars |> Maybe.andThen identity

        -- Resolve the function tvar with cascading fallbacks:
        --   1. Caller-provided tvar (from continuation-body scan for non-recursive let)
        --   2. Self-call scan of def RHS (for multi-def LetRec with direct self-recursion)
        --   3. defBodyTvar (body/return type — last resort)
        funcTvar : Maybe IO.Variable
        funcTvar =
            case defNodeTvar of
                Just _ ->
                    defNodeTvar

                Nothing ->
                    case findVarLocalTvar name exprVars expr of
                        Just v ->
                            Just v

                        Nothing ->
                            defBodyTvar

        letTvar : Maybe IO.Variable
        letTvar =
            TOpt.tvarOf body
    in
    ...
            ofunc =
                TOpt.TrackedFunction argNamesWithTypes wrappedBody
                    { tipe = funcType, tvar = funcTvar }
```

For `args == []` (non-function defs), the `funcTvar` concept doesn't apply — the existing
`defBodyTvar` is correct there. The `funcTvar` is only used in the `_ ->` branch where
`TrackedFunction` is constructed.

---

## Step 4: Compute `defNodeTvar` at `Can.Let` call sites

There are **four** call sites for `optimizeDef` that need updating:

### 4A. `Can.Let` in `optimizeExpr` (non-tail path, line 286)

**Current code**:
```elm
Can.Let def body ->
    let
        ( defName, defType ) =
            getDefNameAndType exprTypes def
    in
    Names.withVarTypes [ ( defName, defType ) ]
        (optimize ... (TCanBuild.toTypedExpr exprTypes exprVars body))
        |> Names.andThen (optimizeDef kernelEnv annotations exprTypes exprVars home cycle def tipe)
```

**Change**: Before calling `optimizeDef`, compute `defNodeTvar` by scanning the
continuation `body` for `VarLocal defName`:
```elm
Can.Let def body ->
    let
        ( defName, defType ) =
            getDefNameAndType exprTypes def

        -- Recover the function type tvar from uses in the continuation body
        defNodeTvar : Maybe IO.Variable
        defNodeTvar =
            findVarLocalTvar defName exprVars body
    in
    Names.withVarTypes [ ( defName, defType ) ]
        (optimize kernelEnv annotations exprTypes exprVars home cycle
            (TCanBuild.toTypedExpr exprTypes exprVars body))
        |> Names.andThen
            (optimizeDef kernelEnv annotations exprTypes exprVars home cycle
                def tipe defNodeTvar)
```

### 4B. `Can.Let` in `optimizeTailExpr` (tail path, line 602)

Identical change, but calls `optimizeTail` instead of `optimize`:
```elm
Can.Let def body ->
    let
        ( defName, defType ) =
            getDefNameAndType exprTypes def

        defNodeTvar : Maybe IO.Variable
        defNodeTvar =
            findVarLocalTvar defName exprVars body
    in
    Names.withVarTypes [ ( defName, defType ) ]
        (optimizeTail kernelEnv annotations exprTypes exprVars home cycle
            rootName argNames resultType (TCanBuild.toTypedExpr exprTypes exprVars body))
        |> Names.andThen
            (optimizeDef kernelEnv annotations exprTypes exprVars home cycle
                def tipe defNodeTvar)
```

### 4C. Multi-def `Can.LetRec` in `optimizeExpr` (line 309)

Pass `Nothing` — the internal self-call scan in `optimizeDefHelp` handles these:
```elm
    _ ->
        Names.withVarTypes defBindings
            (List.foldl
                (\def bod ->
                    Names.andThen
                        (optimizeDef kernelEnv annotations exprTypes exprVars home cycle
                            def tipe Nothing)
                        bod
                )
                (optimize ... (TCanBuild.toTypedExpr exprTypes exprVars body))
                defs
            )
```

### 4D. Multi-def `Can.LetRec` in `optimizeTailExpr` (line 625)

Same — pass `Nothing`:
```elm
    _ ->
        Names.withVarTypes defBindings
            (List.foldl
                (\def bod ->
                    Names.andThen
                        (optimizeDef kernelEnv annotations exprTypes exprVars home cycle
                            def tipe Nothing)
                        bod
                )
                (optimizeTail ... (TCanBuild.toTypedExpr exprTypes exprVars body))
                defs
            )
```

---

## Step 5: Verify `Can.Expr_` variant coverage

Before implementing `findVarLocalTvar`, check all `Can.Expr_` variants are handled.
Read the `Can.Expr_` type definition and ensure exhaustive pattern matching.

Key file: `compiler/src/Compiler/AST/Canonical.elm`, around line 121.

Also verify:
- `Can.Update` field type — is it `Data.Map.Dict ... Can.Expr` or something wrapped?
- `Can.Record` field type — is it `Dict Name Can.Expr`?
- Whether `Data.Map.values` is available (check imports and `Data.Map` module)

---

## Step 6: Build and test

```bash
# Frontend tests
cd compiler && npx elm-test-rs --project build-xhr --fuzz 1

# Full E2E (includes backend/runtime)
cmake --build build --target check
```

Verify no regressions. The fix should be transparent to all downstream passes since:
- `meta.tipe` is unchanged (still the correct function type)
- `meta.tvar` changes from body tvar to function tvar only when found
- MonoDirect sees correct tvars and stops crashing
- `optimizePotentialTailCall` itself is unchanged; only its inputs change

---

## Behavior Summary

| Case | Source of function tvar | Fallback |
|------|------------------------|----------|
| Top-level functions | `annotationVars` via `Module.addDefNode` | (already correct) |
| Lambdas | `tvar` from `TCan.TypedExpr` | (already correct) |
| Single-def `LetRec` (Step 2) | Self-call scan of RHS body | `bodyTvar` (guaranteed to find) |
| Non-recursive `let` (Steps 3-4) | Continuation body scan for `VarLocal` uses | `defBodyTvar` (unused function) |
| Multi-def `LetRec` (Step 3) | Self-call scan of RHS body inside `optimizeDefHelp` | `defBodyTvar` (indirect-only recursion) |

**Edge cases**:
- **Unused local function**: No `VarLocal` found anywhere → falls back to `defBodyTvar`.
  Dead code that won't reach MonoDirect if DCE removes it.
- **Name shadowing**: Not an issue — the compiler's canonicalization phase forbids it.
  All `VarLocal targetName` occurrences refer to the same binding.
- **Polymorphic local functions**: All uses share the same solver variable, so it doesn't
  matter which `VarLocal` occurrence is found first.
