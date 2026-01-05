Here’s a concrete implementation plan for the “Group A / Group B” design, structured so someone can apply it directly to this codebase.

I’ll focus on:

- What to change in each module,
- How the Group A vs Group B paths are wired,
- What existing logic (especially the “extra `CEqual` on unranked vars”) needs to be removed or restricted.

I’ll reference the current code where relevant.

---

## 0. Goal recap

We want:

- A `NodeIdState` / `NodeVarMap` from **expression ID → solver `Variable`** so `Solve.runWithIds` can return a `Dict Int Can.Type` for all expressions.
- To **reuse existing solver variables** that already represent an expression’s type where possible (Group A).
- For remaining forms (Group B), **introduce one extra var per expression** plus a `CEqual` tying it to the expression’s type.
- To **remove the current “one generic `exprVar` per expression + `CEqual`” pattern**, which creates unranked (`noRank`) vars for *every* node and can disturb rank‑based generalization.

The solver (`Compiler.Type.Solve`) should remain unchanged; we only change how we build constraints and how we assign IDs to existing variables.

---

## 1. Identify Group A vs Group B forms

Work in `Compiler.Type.Constrain.Expression` (Expression.elm). The main entry today is:

```elm
constrainProg : RigidTypeVar -> Can.Expr -> E.Expected Type -> Prog Constraint
constrainProg rtv (A.At region exprInfo) expected =
    case exprInfo.node of
        ...
```

with many helpers (`constrainListProg`, `constrainCallProg`, `constrainIfProg`, etc.).

Also, the current WithIds entry is:

```elm
constrainWithIdsProg :
    RigidTypeVar -> Can.Expr -> E.Expected Type -> ProgS ExprIdState Constraint

constrainWithIdsProg rtv (A.At region exprInfo) expected =
    Prog.opMkFlexVarS
        |> Prog.andThenS
            (\exprVar ->
                let
                    exprId   = exprInfo.id
                    exprType = VarN exprVar
                in
                Prog.opModifyS (NodeIds.recordNodeVar exprId exprVar)
                    |> Prog.andThenS
                        (\() ->
                            case exprInfo.node of
                                Can.VarKernel _ _ ->
                                    Prog.pureS CTrue

                                _ ->
                                    let
                                        category = nodeToCategory exprInfo.node
                                    in
                                    constrainNodeWithIdsProg rtv region exprInfo.node expected
                                        |> Prog.mapS
                                            (\con ->
                                                CAnd [ con, CEqual region category exprType expected ]
                                            )
                        )
            )
``` 

That is the “unconditional exprVar + extra `CEqual` on unranked vars” we want to **remove** or restrict to Group B only.

### 1.1 Group A: forms with an existing result `Variable`

From the existing DSL helpers (`constrain…Prog`), the following expression forms already allocate a solver `Variable` that acts as “this expression’s type” and unify it with `expected`:

- `Can.Int _` – uses `mkFlexNumber` and `VarN var` as the literal’s type, equated to `expected`.
- `Can.Negate expr` – `numberVar` is both operand and result type, unified with `expected`.
- `Can.Binop` – `answerVar` is the binop’s result type, unified with `expected`.
- `Can.Call func args` – `resultVar` is the call’s result type, unified with `expected`.
- `Can.If branches finally` – in the non‑annotation branch, `branchVar` is the `if` expression type, unified with `expected`.
- `Can.Case expr branches` – in the non‑annotation branch, `branchVar` is the case expression type, unified with `expected`.
- `Can.Access expr field` – `fieldVar` is the result type of the access (`record.field`), unified with `expected`.
- `Can.Update expr fields` – `recordVar` is the updated record’s type, unified with `expected`.

Patterns via `Pattern.addWithIds` are already treated similarly: `patVar` is the pattern’s type variable, recorded and equated via `CPattern`.

### 1.2 Group B: everything else

All other expression forms don’t have a dedicated result var:

- Fixed‑type literals: `Can.Str _`, `Can.Chr _`, `Can.Float _`, `Can.Unit` (direct `CEqual` to fixed type, no var).
- Collections: lists (`constrainListProg`), records (`constrainRecordProg`), tuples (`constrainTupleProg`) – they build composite `Type` values like `AppN list [...]`, `RecordN`, `TupleN`.
- Lambdas: `props.tipe` is a `FunN` chain; no single `VarN v` for the function as a whole.
- Accessors (`.field`): the expression type is `FunN recordType fieldType`, no result var.
- Variables and foreigns: `Can.VarLocal`, `Can.VarTopLevel`, `Can.VarForeign`, `Can.VarCtor`, `Can.VarDebug`, `Can.VarOperator` – they only produce `CLocal`/`CForeign` with `expected`, types are instantiated inside the solver from the environment.
- Annotated `if`/`case` results: when `expected` is `FromAnnotation`, `constrainIfProg` and `constrainCaseProg` do not allocate branch vars.
- `Can.Let`, `Can.LetRec`, `Can.LetDestruct` nodes themselves: their type is that of the body; constraints don’t assign them a separate var.
- `Can.Shader` and other composite forms: again, composite `Type`, not `VarN v`.

`Can.VarKernel` is special: `constrainProg` returns `CTrue` and does not give it a solver variable at all; its type is handled separately in typed optimization via `KernelTypes`.

---

## 2. High‑level change to `constrainWithIdsProg`

**Module:** `Compiler.Type.Constrain.Expression` (Expression.elm)

### 2.1 Remove the current generic “exprVar + `CEqual`” for all nodes

The existing `constrainWithIdsProg` unconditionally:

- allocates `exprVar` (with `noRank`),
- records `exprId -> exprVar`,
- calls `constrainNodeWithIdsProg`,
- and then adds `CEqual region category exprType expected` for every non‑`VarKernel` expression.

We will **replace** this with:

- A **case split on `exprInfo.node`**:
    - Group A forms: call specialized `constrain…WithIdsProg` that:
        - reuses the existing result var,
        - records it in `NodeIds`,
        - and returns the original constraints unchanged.
    - Group B forms: use a *restricted* generic path that still allocates an `exprVar` and extra `CEqual`, but only for those nodes.

Pseudo‑signature stays the same:

```elm
constrainWithIdsProg :
    RigidTypeVar -> Can.Expr -> E.Expected Type -> ProgS ExprIdState Constraint
```

New skeleton:

```elm
constrainWithIdsProg rtv ((A.At region info) as expr) expected =
    case info.node of
        -- Group A: delegate
        Can.Int _ ->
            constrainIntWithIdsProg rtv region info expected

        Can.Negate e ->
            constrainNegateWithIdsProg rtv region info e expected

        Can.Binop op _ _ annotation left right ->
            constrainBinopWithIdsProg rtv region info.id region op annotation left right expected

        Can.Call func args ->
            constrainCallWithIdsProg rtv region info.id func args expected

        Can.If branches finally ->
            constrainIfWithIdsProg rtv region info.id branches finally expected

        Can.Case e branches ->
            constrainCaseWithIdsProg rtv region info.id e branches expected

        Can.Access expr (A.At accessRegion field) ->
            constrainAccessWithIdsProg rtv region info.id expr accessRegion field expected

        Can.Update expr fields ->
            constrainUpdateWithIdsProg rtv region info.id expr fields expected

        -- VarKernel: keep original behavior
        Can.VarKernel _ _ ->
            Prog.pureS CTrue

        -- Group B default: restricted generic path
        _ ->
            constrainGenericWithIdsProg rtv region info expected
```

You’ll need to introduce new `constrainIntWithIdsProg`, `constrainAccessWithIdsProg`, and adjust existing `…WithIdsProg` helpers to accept the `exprId` where necessary (see next sections).

### 2.2 New restricted generic path for Group B

`constrainGenericWithIdsProg` should be a refactor of your current body, but only used for Group B nodes:

```elm
constrainGenericWithIdsProg :
    RigidTypeVar -> A.Region -> ExprInfo -> E.Expected Type -> ProgS ExprIdState Constraint
constrainGenericWithIdsProg rtv region info expected =
    Prog.opMkFlexVarS
        |> Prog.andThenS
            (\exprVar ->
                let
                    exprId   = info.id
                    exprType = VarN exprVar
                    node     = info.node
                in
                Prog.opModifyS (NodeIds.recordNodeVar exprId exprVar)
                    |> Prog.andThenS
                        (\() ->
                            case node of
                                Can.VarKernel _ _ ->
                                    -- Should not happen: filtered above; keep safe
                                    Prog.pureS CTrue

                                _ ->
                                    let
                                        category = nodeToCategory node
                                    in
                                    constrainNodeWithIdsProg rtv region node expected
                                        |> Prog.mapS
                                            (\con ->
                                                -- Extra CEqual only for Group B
                                                CAnd [ con, CEqual region category exprType expected ]
                                            )
                        )
            )
```

**Important:** Because this is only used for Group B, we have *removed* the problematic “extra `CEqual` on unranked vars” from Group A paths. For Group B, the new var `exprVar` is immediately unified against `expected`; that unification will pull it into the correct pool and rank via `Unify.unify` and `introduce`, so it will not remain “floating” at `noRank`.

---

## 3. Implement Group A “specialized WithIds” helpers

For each Group A form, we need a helper that:

- Mirrors the original `constrain…Prog` logic (so constraints remain identical),
- Allocates the same result var as in the non‑IDs path,
- Records `exprId -> resultVar` in `NodeIds`,
- Returns the constraint.

We will use the stateful DSL (`ProgS`) and `opGetS` / `opModifyS` where we need to read `exprId`.

### 3.1 Int literal

**Module:** `Compiler.Type.Constrain.Expression`

Original (non‑IDs path, in `constrainProg`):

```elm
Can.Int _ ->
    Prog.opMkFlexNumber
        |> Prog.map
            (\var ->
                Type.exists [ var ] (CEqual region E.Number (VarN var) expected)
            )
``` 

New WithIds helper:

```elm
constrainIntWithIdsProg :
    RigidTypeVar -> A.Region -> ExprInfo -> E.Expected Type -> ProgS ExprIdState Constraint
constrainIntWithIdsProg rtv region info expected =
    Prog.opMkFlexNumberS
        |> Prog.andThenS
            (\var ->
                let
                    exprId = info.id
                in
                Prog.opModifyS (NodeIds.recordNodeVar exprId var)
                    |> Prog.mapS
                        (\() ->
                            Type.exists [ var ]
                                (CEqual region E.Number (VarN var) expected)
                        )
            )
```

This is now the only path used for `Can.Int` in `constrainWithIdsProg`.

### 3.2 Negate

Original (non‑IDs):

```elm
constrainNegateProg rtv region expr expected =
    Prog.opMkFlexNumber
        |> Prog.andThen
            (\numberVar ->
                let numberType = VarN numberVar in
                constrainProg rtv expr (FromContext region Negate numberType)
                    |> Prog.map
                        (\numberCon ->
                            let negateCon = CEqual region E.Number numberType expected in
                            Type.exists [ numberVar ] (CAnd [ numberCon, negateCon ])
                        )
            )
``` 

New WithIds:

```elm
constrainNegateWithIdsProg :
    RigidTypeVar -> A.Region -> ExprInfo -> Can.Expr -> E.Expected Type -> ProgS ExprIdState Constraint
constrainNegateWithIdsProg rtv region info expr expected =
    Prog.opMkFlexNumberS
        |> Prog.andThenS
            (\numberVar ->
                let
                    numberType = VarN numberVar
                    exprId     = info.id
                in
                Prog.opModifyS (NodeIds.recordNodeVar exprId numberVar)
                    |> Prog.andThenS
                        (\() ->
                            constrainWithIdsProg rtv expr (FromContext region Negate numberType)
                                |> Prog.mapS
                                    (\numberCon ->
                                        let
                                            negateCon =
                                                CEqual region E.Number numberType expected
                                        in
                                        Type.exists [ numberVar ] (CAnd [ numberCon, negateCon ])
                                    )
                        )
            )
```

Use this in the `Can.Negate` branch of `constrainWithIdsProg`.

### 3.3 Binop

You already have `constrainBinopWithIdsProg`, but it currently:

- Does **not** record the parent expression’s ID, and
- Expects the outer `constrainWithIdsProg` to add the extra `CEqual exprType expected`.

Refactor it to:

- Accept an `exprId : Int`,
- Record `exprId -> answerVar`,
- Keep the final `Constraint` identical to `constrainBinopProg`.

Original non‑IDs path (simplified):

```elm
constrainBinopProg rtv region op annotation leftExpr rightExpr expected =
    Prog.opMkFlexVar
        |> Prog.andThen (\leftVar ->
            Prog.opMkFlexVar
                |> Prog.andThen (\rightVar ->
                    Prog.opMkFlexVar
                        |> Prog.andThen (\answerVar ->
                            ...
                            Type.exists [ leftVar, rightVar, answerVar ]
                                (CAnd
                                    [ opCon
                                    , leftCon
                                    , rightCon
                                    , CEqual region (CallResult (OpName op)) answerType expected
                                    ]
                                )
                        )
                )
        )
```

New WithIds signature:

```elm
constrainBinopWithIdsProg :
    RigidTypeVar
    -> Int                 -- exprId
    -> A.Region
    -> Name.Name
    -> Can.Annotation
    -> Can.Expr
    -> Can.Expr
    -> E.Expected Type
    -> ProgS ExprIdState Constraint
```

Inside:

- Use `Prog.opMkFlexVarS` three times to get `leftVar`, `rightVar`, `answerVar` (as it already does).
- After allocating `answerVar`, record:

  ```elm
  Prog.opModifyS (NodeIds.recordNodeVar exprId answerVar)
  ```

- Then call `constrainWithIdsProg` for `leftExpr` and `rightExpr` (instead of `constrainProg`) and build the same `Type.exists ... CAnd [...]` as in `constrainBinopProg`.

You already have most of this code in `constrainBinopWithIdsProg`; the main edits are “add exprId parameter” and “record NodeIds mapping for `answerVar`”.

### 3.4 Call

Similarly, refactor `constrainCallWithIdsProg` to take `exprId` and record `resultVar`. Its non‑IDs twin is `constrainCallProg`.

Changes:

- Signature:

  ```elm
  constrainCallWithIdsProg :
      RigidTypeVar
      -> A.Region
      -> Int                  -- exprId
      -> Can.Expr
      -> List Can.Expr
      -> E.Expected Type
      -> ProgS ExprIdState Constraint
  ```

- After allocating `resultVar`, record:

  ```elm
  Prog.opModifyS (NodeIds.recordNodeVar exprId resultVar)
  ```

- Keep the rest identical to `constrainCallProg` (using `constrainWithIdsProg` for recursive calls to func/args).

### 3.5 If / Case (unannotated result)

For `If` and `Case`, only the **unannotated result** paths need a result var. The `FromAnnotation` branches don’t have one (Group B).

Refactor `constrainIfWithIdsProg` and `constrainCaseWithIdsProg` to:

- Take an `exprId : Int`,
- When they allocate `branchVar` (the common branch type) in the `_`/non‑annotation case, record:

  ```elm
  Prog.opModifyS (NodeIds.recordNodeVar exprId branchVar)
  ```

- Leave the `FromAnnotation` case alone (no NodeIds mapping; type is already fixed by annotation, and Group B’s generic path will handle it via extra `exprVar + CEqual` if needed).

See `constrainIfWithIdsProg` and `constrainCaseWithIdsProg` for the current structure.

### 3.6 Access and Update

- `constrainAccessWithIdsProg`: add a helper similar to `constrainAccessProg`, but:
    - allocate `fieldVar` and `extVar` as in non‑IDs,
    - record `exprId -> fieldVar`,
    - then return the same `Type.exists [ fieldVar, extVar ] (CAnd [ recordCon, CEqual region (Access field) fieldType expected ])`.

- `constrainUpdateWithIdsProg`: you already have it; modify to:
    - take `exprId`,
    - after allocating `recordVar`, record `exprId -> recordVar`,
    - keep the nested `Type.exists vars (CAnd (fieldsTypeCon :: exprCon :: recordCon :: fieldCons))` identical.

---

## 4. Group B: keep generic + extra `CEqual` (but only for Group B)

For all other expression forms (literals, lists, records, tuples, lambdas, accessors, vars, annotated if/case, shaders, lets, etc.):

- Do **not** try to retrofit a result var.
- Let `constrainGenericWithIdsProg` allocate a single `exprVar` for the node’s ID and add:

  ```elm
  CEqual region category exprType expected
  ```

  in addition to whatever `constrainNodeWithIdsProg` builds (which mirrors `constrainProg`).

Because:

- `exprVar` starts with `rank = noRank` (via `Type.mkFlexVar`).
- `CEqual region category exprType expected` triggers `Unify.unify actual expectedVar` and then `introduce rank pools vars`, which sets the ranks for all involved vars and registers them in the current pool.
- After solving, `Type.toCanType exprVar` sees the same root and content as the composite `Type` that was already being equated to `expected`.

Net effect:

- The **semantics** of type inference are unchanged.
- You get a new “handle” (`exprVar`) for Group B expressions, to use in `runWithIds`.
- The problematic part (“extra CEqual for all expressions”) is now limited to nodes where there was no existing result var, not to Group A.

---

## 5. Module: `Compiler.Type.Constrain.NodeIds`

No functional changes needed, but clarify usage:

- `recordNodeVar : Int -> Variable -> NodeIdState -> NodeIdState` remains the only way to associate an ID with a solver variable.
- After refactor, it will be called:
    - From Group A helpers (with their existing result vars),
    - From `constrainGenericWithIdsProg` (for Group B’s synthetic `exprVar`).

Ensure all new Group A helpers use `NodeIds.recordNodeVar exprId resultVar`.

---

## 6. Module: `Compiler.Type.Constrain.Module`

`constrainWithIds` at module level already calls `Expr.constrainWithIds` and collects the `NodeIdState` mapping; then passes it to `Solve.runWithIds` to build `TypedCanonical` and later typed optimization.

No API changes here; but after refactor:

- The `nodeVars` map now contains:
    - Group A IDs → natural result vars from constraint generation,
    - Group B IDs → synthetic `exprVar`s,
    - Pattern IDs → `patVar`s (unchanged).

`Solve.runWithIds` will still call `Type.toCanType` on each variable and produce `NodeTypes : Dict Int Can.Type`.

---

## 7. Remove / narrow the “unranked `exprVar` + CEqual” pattern

This is the “what needs to be removed” part:

- **Remove the unconditional `Prog.opMkFlexVarS` + `CEqual region category exprType expected` from the current `constrainWithIdsProg`.** That code path must not run for Group A expressions anymore. Only the new `constrainGenericWithIdsProg` (used for Group B nodes) should allocate `exprVar` and add that equality.

- **Do not allocate a generic `exprVar` for Group A nodes at all.** That means:
    - `constrainWithIdsProg` branches on `info.node` and routes Group A cases straight to their specialized helpers.
    - Only Group B cases go through the generic `exprVar` path.

This is what eliminates the old situation where *every* expression had a fresh flex var at `noRank` tied to `expected`.

---

## 8. Sanity checks and testing

1. **TypedCanonical construction**

   `TypedCanonical.fromCanonical` calls `toTypedExpr`, which expects every non‑placeholder ID to have a type in the map; otherwise it crashes.

   After your refactor, ensure:

    - All `Can.Expr` IDs that appear in the module end up in `NodeIds.NodeVarMap`.
    - Group A: via `recordNodeVar` in specialized helpers.
    - Group B: via `recordNodeVar` in `constrainGenericWithIdsProg`.
    - Negative/placeholder IDs (e.g. synthetic nodes) are either not recorded or handled with `TVar "?"` as today.

2. **Constraint equivalence**

   For each Group A helper, verify the final `Constraint` you produce is textually equivalent (modulo ordering in `CAnd` lists) to the one produced by the existing non‑IDs `constrain…Prog`. That ensures no behavior changes in the solver.

3. **Solver unchanged**

   No changes in `Compiler.Type.Solve` are required: it still reads `Constraint`, pools, and your `NodeVarMap`, and then `runWithIds` converts each recorded var to `Can.Type`.

4. **Rank/generalization**

   You can sanity‑check with a few polymorphic let/let‑rec examples to ensure no regressions in type generalization. Group A vars are already in the right `exists`/`CLet` lists; Group B’s `exprVar`s will be pulled into the correct rank via `CEqual exprType expected`.

---

If you follow these steps:

- Group A expressions will use existing solver variables as their ID handles (no extra vars or equalities).
- Group B expressions will still get a separate `exprVar`+`CEqual`, but only where necessary.
- The old “one unranked exprVar and extra `CEqual` for *every* node” code path will be eliminated, which addresses the rank/generalization concern.

