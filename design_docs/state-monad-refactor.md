Here’s a concrete plan you could actually implement, based on the current codebase.

Key idea:

- Keep `System.TypeCheck.IO` as the **single core primitive IO monad** (the low‑level state + primitive “effects”) .
- Build **two higher‑level DSLs** on top:
    - A **constraint‑generation DSL** that walks expressions/patterns and *builds constraints* without deep IO call chains.
    - A **solver/unifier DSL** that walks the `Constraint` tree and performs unification (you already have most of this in `Solve.solve` + `Unify.Unify`).

The DSLs both *interpret down into* `System.TypeCheck.IO.IO`.

Below I’ll focus most on the constraint DSL, because that’s where your stack overflow comes from. I’ll still describe what to do (or not do) on the solver side.

---

## 0. Leave `System.TypeCheck.IO` as the core primitive

Do **not** change these:

- `type alias IO a = State -> ( State, a )` and `State` in `System.TypeCheck.IO` .
- `IO.pure`, `IO.map`, `IO.andThen`, `IO.loop`, etc. .
- `Data.IORef`, `Compiler.Type.UnionFind`, `Data.Vector`, `Data.Vector.Mutable`, etc. that work directly with `IO` and the underlying arrays  .
- `Compiler.Type.Type` operations like `mkFlexVar`, `mkFlexNumber`, `toAnnotation`, `toCanType`, which all use `IO` .
- `Compiler.Type.Solve`’s main loop (`solve`, `solveHelp`, `IO.loop`) .
- `Compiler.Type.Unify.Unify` (its CPS structure is already a DSL layered over `IO`) .

This **keeps the low‑level store and union‑find unchanged** and avoids a huge invasive rewrite.

Our changes will be *above* this level.

---

## 1. New constraint DSL: `Compiler.Type.Constrain.Program`

Create a new module:

```elm
module Compiler.Type.Constrain.Program exposing
    ( Prog
    , pure, map, andThen
    , run
    , opMkFlexVar
    , opConstrainExpr
    , opConstrainPattern
    )
```

### 1.1. Program type

Define a *defunctionalized* program type representing constraint‑generation steps, plus an explicit worklist/stack:

```elm
type Prog a
    = Done a
    | Step (Instr a)


-- One "instruction" in the DSL.
type Instr a
    = MkFlexVar (IO.Variable -> Prog a)
    | ConstrainExpr
        { rtv : Compiler.Type.Constrain.Expression.RigidTypeVar
        , expr : Can.Expr
        , expected : E.Expected Type
        , k : Constraint -> Prog a
        }
    | ConstrainPattern
        { pattern : Can.Pattern
        , expected : E.PExpected Type
        , k : Pattern.State -> Prog a
        }
    | Bind (Prog a) (a -> Prog a)
```

Notes:

- `MkFlexVar` encapsulates “allocate a new flex var” (`Type.mkFlexVar`).
- `ConstrainExpr` wraps “constrain this expression with RTV + expectation”.
- `ConstrainPattern` wraps `Pattern.add`.
- `Bind` is just the monadic bind reified as data.

We will *not* recurse directly in `constrain` anymore; we instead build a `Prog` value composed of these instructions.

### 1.2. Monad operations

Define the usual:

```elm
pure : a -> Prog a
pure a =
    Done a


map : (a -> b) -> Prog a -> Prog b
map f p =
    andThen (f >> pure) p


andThen : (a -> Prog b) -> Prog a -> Prog b
andThen k p =
    Step (Bind p k)
```

### 1.3. Smart constructors for instructions

Expose helper functions:

```elm
opMkFlexVar : Prog IO.Variable
opMkFlexVar =
    Step (MkFlexVar Done)


opConstrainExpr :
    Compiler.Type.Constrain.Expression.RigidTypeVar
    -> Can.Expr
    -> E.Expected Type
    -> Prog Constraint
opConstrainExpr rtv expr expected =
    Step (ConstrainExpr { rtv = rtv, expr = expr, expected = expected, k = Done })


opConstrainPattern :
    Can.Pattern
    -> E.PExpected Type
    -> Prog Pattern.State
opConstrainPattern pattern expected =
    Step (ConstrainPattern { pattern = pattern, expected = expected, k = Done })
```

These will be used by the constraint modules instead of “direct IO + recursion”.

### 1.4. Interpreter: `run : Prog a -> IO a`

Implement a tail‑recursive interpreter that executes a `Prog` in `IO` without growing the JS stack:

```elm
run : Prog a -> IO a
run program0 =
    IO.loop step ( program0, [] )


type alias Frame a =
    a -> Prog a


step : ( Prog a, List (Frame a) ) -> IO (IO.Step ( Prog a, List (Frame a) ) a)
step ( program, stack ) =
    case program of
        Done value ->
            case stack of
                [] ->
                    -- Finished
                    IO.pure (IO.Done value)

                frame :: rest ->
                    -- Tail "return" into next continuation
                    IO.pure (IO.Loop ( frame value, rest ))

        Step instr ->
            case instr of
                Bind sub k ->
                    -- Reassociate: execute sub, then k; no nested calls
                    IO.pure (IO.Loop ( sub, k :: stack ))

                MkFlexVar k ->
                    Type.mkFlexVar
                        |> IO.map
                            (\var ->
                                IO.Loop ( k var, stack )
                            )

                ConstrainExpr { rtv, expr, expected, k } ->
                    -- We will route this back to a non-DSL helper in Expression, see below
                    Compiler.Type.Constrain.Expression.constrainStep rtv expr expected
                        |> IO.map
                            (\con ->
                                IO.Loop ( k con, stack )
                            )

                ConstrainPattern { pattern, expected, k } ->
                    Compiler.Type.Constrain.Pattern.addStep pattern expected
                        |> IO.map
                            (\state ->
                                IO.Loop ( k state, stack )
                            )
```

Key property: **there is only one recursive call path**—through `IO.loop`, which is already implemented as a tail‑recursive loop in `System.TypeCheck.IO` . All `Bind` and nested work is handled via the explicit `stack`, not the JS call stack.

We will now refactor constraint generation so that it:

- builds a `Prog` value,
- then calls `Program.run` at the outer boundary.

---

## 2. Refactor `Compiler.Type.Constrain.Expression` to use the DSL

This module produces most of the deep IO chains today .

### 2.1. Add a “one‑step” helper: `constrainStep`

In `Compiler.Type.Constrain.Expression` (same module), introduce a new **_non‑recursive_**, one‑step function:

```elm
constrainStep :
    RigidTypeVar
    -> Can.Expr
    -> E.Expected Type
    -> IO Constraint
constrainStep rtv ((A.At region exprInfo) as expr) expected =
    case exprInfo.node of
        -- Keep all simple cases in IO directly:

        Can.VarLocal name ->
            IO.pure (CLocal region name expected)

        Can.VarTopLevel _ name ->
            IO.pure (CLocal region name expected)

        Can.VarKernel _ _ ->
            IO.pure CTrue

        Can.VarForeign _ name annotation ->
            IO.pure (CForeign region name annotation expected)

        ...
        Can.Int _ ->
            Type.mkFlexNumber
                |> IO.map
                    (\var ->
                        Type.exists [ var ] (CEqual region E.Number (VarN var) expected)
                    )

        -- For complex recursive forms, *do not* call constrain recursively here.
        -- Instead, delegate to DSL-building helpers described below.

        Can.If branches finalExpr ->
            constrainIfProg rtv region branches finalExpr expected
                |> Program.run

        Can.Binop op _ leftExpr rightExpr ->
            constrainBinopProg rtv region op leftExpr rightExpr expected
                |> Program.run

        Can.Tuple a b cs ->
            constrainTupleProg rtv region a b cs expected
                |> Program.run

        Can.List elements ->
            constrainListProg rtv region elements expected
                |> Program.run

        Can.Record fields ->
            constrainRecordProg rtv region fields expected
                |> Program.run

        Can.Update expr fields ->
            constrainUpdateProg rtv region expr fields expected
                |> Program.run

        -- etc. For each recursive expression form, add a `...Prog` helper.
```

The idea:

- `constrainStep` **does at most one layer of IO** and never recurses; it may delegate to `...Prog` helpers that use the DSL.

- simple leaf cases can just return `IO.pure ...` as before.

### 2.2. New `...Prog` helpers that build `Prog`

Now for a recursive case like the binop you highlighted (and where stack overflow happens), define a *pure* DSL program builder.

Before, you had something like (simplified):

```elm
constrainBinop rtv region op annotation leftExpr rightExpr expected =
    Type.mkFlexVar
        |> IO.andThen (\leftVar -> ...)
        -- nested IO chains...
```

Refactor to:

```elm
constrainBinopProg :
    RigidTypeVar
    -> A.Region
    -> Can.Binop
    -> Can.Expr
    -> Can.Expr
    -> E.Expected Type
    -> Program.Prog Constraint
constrainBinopProg rtv region op leftExpr rightExpr expected =
    Program.opMkFlexVar
        |> Program.andThen
            (\leftVar ->
                Program.opMkFlexVar
                    |> Program.andThen
                        (\rightVar ->
                            Program.opMkFlexVar
                                |> Program.andThen
                                    (\answerVar ->
                                        let
                                            leftType  = VarN leftVar
                                            rightType = VarN rightVar
                                            ansType   = VarN answerVar
                                        in
                                        -- Note: these recursive calls are now through the DSL:
                                        Program.opConstrainExpr rtv leftExpr (E.NoExpectation leftType)
                                            |> Program.andThen
                                                (\leftCon ->
                                                    Program.opConstrainExpr rtv rightExpr (E.NoExpectation rightType)
                                                        |> Program.map
                                                            (\rightCon ->
                                                                -- build final constraint *purely*:
                                                                let
                                                                    binopCon = ...  -- same as before
                                                                in
                                                                Type.exists
                                                                    [ leftVar, rightVar, answerVar ]
                                                                    (CAnd [ leftCon, rightCon, binopCon ])
                                                            )
                                                )
                                    )
                        )
            )
```

Key: **This is purely building a `Prog Constraint` value**; no IO occurs here.

Then `constrainStep` calls `constrainBinopProg ... |> Program.run`, which:

- uses `MkFlexVar` instructions to call `Type.mkFlexVar` in small, flat IO steps,
- uses `ConstrainExpr` to delegate recursive sub‑expressions back into `constrainStep` in a loop, not via recursion.

You repeat this pattern for:

- `constrainIf` / `constrainIfProg` (if‑expressions; a huge contributor to nesting) .
- `constrainTuple` / `constrainTupleProg` (has lots of nested `IO.andThen` today) .
- lists, records, record updates (each has multi‑step IO chains now) .
- destructuring (`constrainDestruct`, `constrainDestructWithIds`) .

Strategy:

1. For each recursive `constrain*` that currently uses nested `IO.andThen`:
    - extract its core logic into a **pure** `...Prog` builder returning `Prog Constraint` or `Prog (Constraint, ExprIdState)` etc.
    - replace the old function with a thin wrapper:
        - calls `...Prog` to build a `Prog`,
        - then `Program.run` to execute it into `IO`.

2. Inside `...Prog`, any recursive call to `constrain` must become `Program.opConstrainExpr ...`.

3. Any `Type.mkFlexVar` / `Type.mkFlexNumber` that was chained with `IO.andThen` becomes `Program.opMkFlexVar`.

4. Any pattern constraint (`Pattern.add` / `Pattern.addWithIds`) moves through a similar DSL op (`Program.opConstrainPattern`) or through a Pattern‑specific DSL (next section).

This removes the nested IO bind chains for the entire constraint tree construction.

---

## 3. Refactor `Compiler.Type.Constrain.Pattern` similarly

`Pattern.add` and `addTuple` have the same deep `IO.andThen` chains .

### 3.1. Add `addStep` and `addWithIdsStep`

In `Compiler.Type.Constrain.Pattern` add “one‑step” variants:

```elm
addStep : Can.Pattern -> E.PExpected Type -> IO State
addStep (A.At region patternInfo) expectation state =
    case patternInfo.node of
        Can.PAnything ->
            IO.pure state

        Can.PVar name ->
            IO.pure (addToHeaders region name expectation state)

        Can.PAlias realPattern name ->
            -- delegate to DSL-based aliasProg
            aliasProg region realPattern name expectation state
                |> Program.runPattern

        Can.PUnit ->
            ... -- same as today

        Can.PTuple a b cs ->
            addTupleProg region a b cs expectation state
                |> Program.runPattern

        -- and so on, for PList, PCons, PRecord, PCtor, etc.
```

Here `Program.runPattern` is either:

- another function in `Compiler.Type.Constrain.Program` specialized for pattern programs, or
- you treat pattern programs as the same `Prog`, returning `State` or `(State, NodeIds.NodeIdState)`.

### 3.2. Pattern DSL (optional split)

You have two options:

- Re‑use `Program.Prog` for patterns too, with extra constructors (e.g. `PatternMkFlexVar`, `PatternBind`) and a `runPattern : Prog State -> IO State`.

- Or create a separate `PatternProg` type and interpreter in `Pattern` itself that works analogously (and still runs in `IO`).

Either way, the structure mirrors what you did for expressions:

- pattern combinators (e.g. `addTuple`, `addEntry`) become **pure program builders** (`addTupleProg`, etc.).
- recursion between patterns uses `opConstrainPattern`/pattern DSL ops, not direct recursion in IO.

---

## 4. Refactor `Compiler.Type.Constrain.Module`

`Compiler.Type.Constrain.Module` strings together the expression/pattern constraint functions at declaration/module level .

### 4.1. Keep the API, change internals

Public APIs:

```elm
constrain : Can.Module -> IO Constraint 
constrainWithIds : Can.Module -> IO ( Constraint, NodeIds.NodeVarMap ) 
```

These can remain. Internally:

- `constrainDecls` currently uses a functional accumulator + `IO.andThen (Expr.constrainDef ...)` .
- Refactor so that `Expr.constrainDef` itself uses the new DSL internally; from the module’s perspective, it still just returns `IO Constraint`.

Because `Expr.constrainDef` / `constrainRecursiveDefs` will internally call DSL builders + `Program.run`, `Module` doesn’t need explicit knowledge of the DSL. It can remain mostly as is:

```elm
constrainDeclsHelp decls finalConstraint cont =
    case decls of
        Can.Declare def otherDecls ->
            constrainDeclsHelp otherDecls finalConstraint
                (IO.andThen (Expr.constrainDef Dict.empty def) >> cont)

        Can.DeclareRec def defs otherDecls ->
            constrainDeclsHelp otherDecls finalConstraint
                (IO.andThen (Expr.constrainRecursiveDefs Dict.empty (def :: defs)) >> cont)

        Can.SaveTheEnvironment ->
            cont (IO.pure finalConstraint)
```

Because the *internal shape* of `Expr.constrainDef` no longer stacks `andThen` deeply (it just runs a big DSL program via `Program.run`), the overall module‑level stack usage will also be safe.

Likewise for the `constrainWithIds` variants, which go through `Expr.constrainDefWithIds` / `constrainRecursiveDefsWithIds`  .

---

## 5. Solver / unification DSL

On the *solver* side, you already have:

- A constraint AST: `Type.Constraint` (`CTrue`, `CAnd`, `CLet`, etc.) .
- A main solver loop implemented using `IO.loop`:

  ```elm
  solve env rank pools state constraint =
      IO.loop solveHelp ( ( env, rank ), ( pools, state ), ( constraint, identity ) ) 
  ```

  where `solveHelp` inspects one `Constraint` and returns either `Loop` (continue) or `Done` (finish) .

- A unification DSL `Unify a = Unify (List IO.Variable -> IO (Result UnifyErr (UnifyOk a)))`, with its own `map`, `pure`, and `andThen` that internally call `IO.andThen` but are much narrower in scope .

This is already *very close* to the “second DSL on top of core IO”. You can treat:

- the `Constraint` tree + `solve`/`solveHelp` + `Unify` as the **solver DSL**;
- the new `Constrain.Program.Prog` as the **constraint DSL**.

If you want to align them stylistically, you can:

1. Introduce a small `Compiler.Type.Solve.Program` module that gives names to the pattern `IO.loop solveHelp` uses:

    - `type alias SolveProg a = ( (Env, Int), (Pools, State), (Constraint, IO State -> IO State) )`
    - `step : SolveProg a -> IO (IO.Step SolveProg a)` (already there as `solveHelp`) .
    - `run : Constraint -> IO State` (already there as `solve`).

   This is mostly renaming and documentation—no functional change.

2. Optionally, if you find stack issues in unification, you could take the same approach as for constraint building:
    - Push more of the recursion into a CPS/free‑monad‑style layer above IO (similar to current `Unify`), and
    - Ensure all higher‑level loops go through `IO.loop`.

At this stage, though, the *actual stack overflow* is in constraint generation, not the solver, so refactoring the solver is not urgent.

---

## 6. Impacted modules and types (summary)

Here is the impact surface:

### 6.1. New module

- `Compiler.Type.Constrain.Program`
    - Defines `Prog`, `Instr`, monad ops, and `run`.
    - Possibly also pattern‑specific helpers (`runPattern`, pattern instructions).

### 6.2. Modified modules: constraint generation

1. `Compiler.Type.Constrain.Expression`

    - Add `constrainStep : RigidTypeVar -> Can.Expr -> E.Expected Type -> IO Constraint`.
    - For each recursive helper (e.g. `constrainBinop`, `constrainIf`, `constrainTuple`, `constrainRecord`, `constrainUpdate`, `constrainDestruct`, and their `WithIds` variants):
        - Extract a `...Prog` builder returning `Prog Constraint` or `Prog (Constraint, ExprIdState)`.
        - Implement original function in terms of `...Prog |> Program.run`.
    - Everywhere that currently calls `constrain` recursively inside IO needs to switch to `Program.opConstrainExpr` inside a `Prog` builder.

2. `Compiler.Type.Constrain.Pattern`

    - Add `addStep : Can.Pattern -> E.PExpected Type -> State -> IO State`.
    - For recursive helpers (`addTuple`, list/cons/record/ctor patterns, and `addWithIds` variants) that currently use nested `IO.andThen`:
        - Extract `...Prog` variants that build `Prog State` or `Prog (State, NodeIds.NodeIdState)`.
        - Implement the old functions in terms of those + `Program.run` (or a pattern‑specific runner).
    - Call these from `constrainDestructProg` / `constrainDestructWithIdsProg` in `Expression`.

3. `Compiler.Type.Constrain.Module`

    - No signature changes.
    - Internal calls to `Expr.constrainDef` / `Expr.constrainRecursiveDefs` remain, but those functions will now use the DSL internally, eliminating deep IO chaining.

4. Any “with IDs” tracking functions:

    - `constrainWithIds` / `constrainDeclsWithVars` in `Constrain.Module`  .
    - `constrainWithIds`, `constrainDefWithIds`, `constrainRecursiveDefsWithIds` in `Constrain.Expression` .
    - `addWithIds` and helpers in `Constrain.Pattern` .

   All of these should delegate to DSL programs similarly but keep their external IO signatures the same.

### 6.3. Solver side

- `Compiler.Type.Solve` :
    - You can leave as is. Optionally, document it in terms of a “SolveProgram” DSL, but no functional change is required initially.

- `Compiler.Type.Unify` :
    - Already uses CPS + IO; no mandatory change.

No changes to:

- `System.TypeCheck.IO` .
- `Data.IORef`, `Compiler.Type.UnionFind`, `Data.Vector`, `Data.Vector.Mutable`  .
- `Compiler.Type.Type`, `Compiler.Type.Instantiate`, `Compiler.Type.Error`, etc. .

---

## 7. Rollout strategy

1. **Introduce the DSL module and run function** (`Compiler.Type.Constrain.Program`) without changing any callers.

2. Convert **one hot path** first (e.g. `constrainBinop`):

    - Implement `constrainBinopProg` using `Prog`.
    - Change `constrainStep`’s binop case to call `constrainBinopProg |> Program.run`.
    - Run fuzz tests for binop chains and nested `if`s to verify stack behavior.

3. Gradually convert the remaining complex recursive cases:

    - `if`, tuple, list, record, destructures.
    - `WithIds` variants.

4. Once all recursive shapes are through DSL programs, run:

    - Your existing typechecker tests.
    - The fuzzer with Boolean/Append chain length increased (try 3, 4, etc.) to confirm stack no longer overflows.

5. Optionally re‑organize/document solver as a “second DSL” for conceptual clarity.

---

If you’d like, we can now pick one concrete function (e.g. the binop constraint you showed, or `constrainIf`) and walk through an exact before/after transformation in more code‑level detail.

