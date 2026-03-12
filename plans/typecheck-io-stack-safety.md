# TypeCheck IO Stack Safety: Convert Unsafe Traversals to `IO.loop`

## Problem

Stage 5 of the bootstrap (MLIR output) crashes with `Maximum call stack size exceeded` at
`System.TypeCheck.IO.andThen` (eco-boot-2.js:54328) after compiling 54 of 231 modules.

Several `System.TypeCheck.IO` combinators and hand-rolled recursive patterns build closure
chains proportional to collection/declaration size. When JS executes these chains, each link
adds a stack frame, eventually overflowing. The same problem affects two other custom monads
(`Control.Monad.State.TypeCheck.Strict.StateT` and `Compiler.LocalOpt.*.Names.Tracker`).

## Approach

`IO.elm` already has safe patterns: `foldM`, `foldrM`, `traverseMap`, `traverseMapWithKey`,
`mapM_`, `forM_` — all use `IO.loop` with a `Step` type (`Loop state | Done a`). The fix is
to rewrite the unsafe combinators and call sites to follow the same `loop`-based pattern.

**One new module**: A shared `Control.Loop` module exposing `type Step state a = Loop state
| Done a` so that non-IO monads (the `Tracker` types) can also use loop patterns without
depending on `System.TypeCheck.IO`.

No changes to `IO`'s core types (`IO`, `State`, `andThen`, `map`, `pure`, `loop`). `IO.Step`
will be kept as-is (or re-exported from `Control.Loop`). Only the higher-level combinators and
their call sites change.

---

## Phase 0: Shared `Step` Type

### Step 0.1: Create `Control.Loop` Module

**New file: `compiler/src/Control/Loop.elm`**

```elm
module Control.Loop exposing (Step(..))

type Step state a
    = Loop state
    | Done a
```

This is the same type as `IO.Step` but independent of `IO`. It will be used by:
- `Compiler.LocalOpt.Typed.Names` (Tracker monad)
- `Compiler.LocalOpt.Erased.Names` (Tracker monad)

### Step 0.2: Re-export from `IO`

Update `System.TypeCheck.IO` to re-export `Control.Loop.Step` instead of defining its own.
This ensures all existing code that uses `IO.Step`, `IO.Loop`, `IO.Done` continues to work
with zero call-site changes.

```elm
-- In System.TypeCheck.IO:
import Control.Loop exposing (Step(..))
-- Remove the local `type Step` definition
-- Keep `Step(..)` in the module's exposing list
```

---

## Phase 1 (P0): Module-Level Declaration Traversals

These are the most likely crash triggers — chain depth = number of top-level declarations in
a module, which can be hundreds.

### Step 1.1: Typed/Module.elm — `constrainDeclsWithVarsHelp`

**Current** (line 93): Tail-recursive on `Decls`, but chains `IO.andThen` at each level:
```elm
constrainDeclsWithVarsHelp decls finalConstraint state =
    case decls of
        Can.Declare def otherDecls ->
            constrainDeclsWithVarsHelp otherDecls finalConstraint state
                |> IO.andThen (\( bodyCon, newState ) ->
                    Expr.constrainDefWithIds DMap.empty def bodyCon newState)
        Can.DeclareRec def defs otherDecls ->
            constrainDeclsWithVarsHelp otherDecls finalConstraint state
                |> IO.andThen (\( bodyCon, newState ) ->
                    Expr.constrainRecursiveDefsWithIds DMap.empty (def :: defs) bodyCon newState)
        Can.SaveTheEnvironment ->
            IO.pure ( finalConstraint, state )
```

This recurses to the end first, then builds a chain of N `andThen` closures that all execute
on unwind. The pattern is essentially `foldr` with `IO.andThen`.

**State threading analysis**: `ExprIdState` (`NodeIdState`) contains a `NodeVarMap` (array of
`Maybe IO.Variable`) and a `syntheticExprIds` set. Both are purely additive — entries are only
appended, never removed or overwritten. Each declaration adds mappings at independent array
indices (expression/pattern IDs are assigned during canonicalization, not constraint
generation). Therefore state threading order is irrelevant — left-to-right produces the same
final state as right-to-left.

**Fix**: Flatten the `Decls` linked list into a `List`, then process last-to-first using
`IO.loop`. The original processes declarations last-to-first (recurse to `SaveTheEnvironment`,
then unwind). Each declaration wraps the constraint of all subsequent declarations via
`constrainDefWithIds ... bodyCon`. We reverse the flattened list so the loop processes in the
same last-to-first order.

```elm
type DeclItem
    = Single Can.Def
    | Rec Can.Def (List Can.Def)


flattenDecls : Can.Decls -> List DeclItem -> List DeclItem
flattenDecls decls acc =
    case decls of
        Can.Declare def rest ->
            flattenDecls rest (Single def :: acc)
        Can.DeclareRec def defs rest ->
            flattenDecls rest (Rec def defs :: acc)
        Can.SaveTheEnvironment ->
            List.reverse acc


constrainDeclsWithVarsHelp decls finalConstraint state =
    IO.loop constrainDeclsWithVarsStep
        ( List.reverse (flattenDecls decls []), finalConstraint, state )


constrainDeclsWithVarsStep :
    ( List DeclItem, Constraint, ExprIdState )
    -> IO (Step ( List DeclItem, Constraint, ExprIdState ) ( Constraint, ExprIdState ))
constrainDeclsWithVarsStep ( items, bodyCon, state ) =
    case items of
        [] ->
            IO.pure (Done ( bodyCon, state ))

        (Single def) :: rest ->
            Expr.constrainDefWithIds DMap.empty def bodyCon state
                |> IO.map (\( con, newState ) -> Loop ( rest, con, newState ))

        (Rec def defs) :: rest ->
            Expr.constrainRecursiveDefsWithIds DMap.empty (def :: defs) bodyCon state
                |> IO.map (\( con, newState ) -> Loop ( rest, con, newState ))
```

Note: `List.reverse (flattenDecls decls [])` gives declarations in last-to-first order.
`flattenDecls` accumulates left-to-right with cons + final reverse, so `flattenDecls` returns
first-to-last. Reversing that gives last-to-first. Each loop iteration processes one
declaration, passing the resulting constraint as `bodyCon` to the next (earlier) declaration.

### Step 1.2: Erased/Module.elm — `constrainDeclsHelp`

**Current** (line 79): CPS-style accumulation of `IO.andThen` chains:
```elm
constrainDeclsHelp decls finalConstraint cont =
    case decls of
        Can.Declare def otherDecls ->
            constrainDeclsHelp otherDecls finalConstraint
                (IO.andThen (Expr.constrainDef DMap.empty def) >> cont)
        Can.DeclareRec def defs otherDecls ->
            constrainDeclsHelp otherDecls finalConstraint
                (IO.andThen (Expr.constrainRecursiveDefs DMap.empty (def :: defs)) >> cont)
        Can.SaveTheEnvironment ->
            cont (IO.pure finalConstraint)
```

Same problem: builds a chain of N composed `IO.andThen` closures via `cont`.

**Fix**: Same approach — flatten `Decls` to `List DeclItem`, iterate last-to-first with
`IO.loop`. The `DeclItem` type and `flattenDecls` can be duplicated here (small helper) or
extracted to a shared location if desired.

```elm
constrainDecls decls finalConstraint =
    IO.loop constrainDeclsStep
        ( List.reverse (flattenDecls decls []), finalConstraint )


constrainDeclsStep :
    ( List DeclItem, Constraint )
    -> IO (Step ( List DeclItem, Constraint ) Constraint)
constrainDeclsStep ( items, bodyCon ) =
    case items of
        [] ->
            IO.pure (Done bodyCon)

        (Single def) :: rest ->
            Expr.constrainDef DMap.empty def bodyCon
                |> IO.map (\con -> Loop ( rest, con ))

        (Rec def defs) :: rest ->
            Expr.constrainRecursiveDefs DMap.empty (def :: defs) bodyCon
                |> IO.map (\con -> Loop ( rest, con ))
```

No state threading needed here (erased variant doesn't track `ExprIdState`).

---

## Phase 2 (P1): IO.elm Combinators

### Step 2.1: `IO.traverseList` / `IO.mapM`

**Current** (line 300):
```elm
traverseList f =
    List.foldr (\a -> andThen (\c -> map (\va -> va :: c) (f a)))
        (pure [])
```

This builds N nested `andThen` closures via `List.foldr`.

**Fix**: Rewrite using `loop`, following the exact same pattern as `foldM`/`foldrM`. Process
left-to-right and reverse at the end (left-to-right evaluation order is acceptable):

```elm
traverseList : (a -> IO b) -> List a -> IO (List b)
traverseList f list =
    loop (traverseListHelp f) ( list, [] )
        |> map List.reverse


traverseListHelp : (a -> IO b) -> ( List a, List b ) -> IO (Step ( List a, List b ) (List b))
traverseListHelp f ( remaining, acc ) =
    case remaining of
        [] ->
            pure (Done acc)

        a :: rest ->
            map (\b -> Loop ( rest, b :: acc )) (f a)
```

`mapM` is already just an alias for `traverseList` — no change needed there.

### Step 2.2: `IO.foldMDict`

**Current** (line 290):
```elm
foldMDict keyComparison f b =
    Dict.foldl keyComparison (\_ a -> andThen (\acc -> f acc a)) (pure b)
```

Builds N nested `andThen` closures via `Dict.foldl`.

**Fix**: Convert `Dict` to list of values, then use `loop`. `Dict.values` traverses in the
same key order as `Dict.foldl`:

```elm
foldMDict : (k -> k -> Order) -> (b -> a -> IO b) -> b -> Dict comparable k a -> IO b
foldMDict keyComparison f b dict =
    loop (foldMDictHelp f) ( Dict.values keyComparison dict, b )


foldMDictHelp : (b -> a -> IO b) -> ( List a, b ) -> IO (Step ( List a, b ) b)
foldMDictHelp f ( remaining, acc ) =
    case remaining of
        [] ->
            pure (Done acc)

        a :: rest ->
            map (\newAcc -> Loop ( rest, newAcc )) (f acc a)
```

### Step 2.3: `toCanTypeBatch` (in `Compiler/Type/Type.elm`)

**Current** (line 447): Uses `Array.foldl` + `IO.andThen`:
```elm
toCanTypeBatch nodeVars =
    Array.foldl
        (\maybeVar accIO ->
            case maybeVar of
                Nothing -> accIO
                Just var -> IO.andThen (\names -> getVarNames var names) accIO
        )
        (IO.pure Dict.empty)
        nodeVars
        |> IO.andThen (\allUserNames -> ...)
```

**Fix**: Convert array to list and use the already-safe `IO.foldM`:

```elm
toCanTypeBatch nodeVars =
    IO.foldM
        (\names maybeVar ->
            case maybeVar of
                Nothing -> IO.pure names
                Just var -> getVarNames var names
        )
        Dict.empty
        (Array.toList nodeVars)
        |> IO.andThen (\allUserNames -> ...)
```

---

## Phase 3 (P2): `Control.Monad.State.TypeCheck.Strict.StateT`

### Step 3.1: `StateT.traverseList`

**Current** (line 144):
```elm
traverseList f =
    List.foldr (\a -> andThen (\c -> map (\va -> va :: c) (f a)))
        (pure [])
```

Identical pattern to `IO.traverseList`. Same problem: N nested `andThen` closures.

**Fix**: Unwrap `StateT` to `IO` and use `IO.loop` internally. `StateT` wraps
`StateT (s -> IO ( a, s ))`:

```elm
traverseList : (a -> StateT s b) -> List a -> StateT s (List b)
traverseList f list =
    StateT (\s0 ->
        IO.loop (traverseListSTHelp f) ( list, [], s0 )
            |> IO.map (\( results, sFinal ) -> ( List.reverse results, sFinal ))
    )


traverseListSTHelp :
    (a -> StateT s b)
    -> ( List a, List b, s )
    -> IO (IO.Step ( List a, List b, s ) ( List b, s ))
traverseListSTHelp f ( remaining, acc, s ) =
    case remaining of
        [] ->
            IO.pure (IO.Done ( acc, s ))

        a :: rest ->
            runStateT (f a) s
                |> IO.map (\( b, s1 ) -> IO.Loop ( rest, b :: acc, s1 ))
```

### Step 3.2: `StateT.traverseMapWithKey`

**Current** (line 164):
```elm
traverseMapWithKey keyComparison toComparable f =
    Dict.foldl keyComparison
        (\k a -> andThen (\c -> map (\va -> Dict.insert toComparable k va c) (f k a)))
        (pure Dict.empty)
```

**Fix**: Same unwrap-to-IO approach:

```elm
traverseMapWithKey : ... -> Dict comparable k a -> StateT s (Dict comparable k b)
traverseMapWithKey keyComparison toComparable f dict =
    StateT (\s0 ->
        IO.loop (traverseMapSTHelp toComparable f)
            ( Dict.toList keyComparison dict, Dict.empty, s0 )
    )


traverseMapSTHelp :
    (k -> comparable)
    -> (k -> a -> StateT s b)
    -> ( List ( k, a ), Dict comparable k b, s )
    -> IO (IO.Step ( List ( k, a ), Dict comparable k b, s ) ( Dict comparable k b, s ))
traverseMapSTHelp toComparable f ( pairs, acc, s ) =
    case pairs of
        [] ->
            IO.pure (IO.Done ( acc, s ))

        ( k, a ) :: rest ->
            runStateT (f k a) s
                |> IO.map (\( b, s1 ) ->
                    IO.Loop ( rest, Dict.insert toComparable k b acc, s1 ))
```

Note: `StateT.traverseMap` delegates to `traverseMapWithKey` so it gets the fix for free.

---

## Phase 4 (P3): LocalOpt Names Tracker Monads

These pure state monads don't use `IO`. They need their own `loop` combinator, using the
shared `Control.Loop.Step` type from Phase 0.

### Step 4.1: `Compiler.LocalOpt.Typed.Names` — Add `loop`, Rewrite `traverse`

The `Tracker` monad threads 4 state fields: `uid`, `deps`, `fields`, `locals`.

**Add `loop`:**
```elm
import Control.Loop exposing (Step(..))

loop : (state -> Tracker (Step state a)) -> state -> Tracker a
loop callback loopState =
    Tracker (\n d f l ->
        loopHelper callback loopState n d f l
    )


loopHelper : (state -> Tracker (Step state a)) -> state -> Int -> Deps -> Fields -> Locals -> TResult a
loopHelper callback loopState n d f l =
    case callback loopState of
        Tracker k ->
            case k n d f l of
                TResult props (Loop newState) ->
                    loopHelper callback newState props.uid props.deps props.fields props.locals

                TResult props (Done a) ->
                    TResult props a
```

**Rewrite `traverse`:**
```elm
traverse : (a -> Tracker b) -> List a -> Tracker (List b)
traverse func list =
    loop (\( remaining, acc ) ->
        case remaining of
            [] -> pure (Done (List.reverse acc))
            a :: rest -> map (\b -> Loop ( rest, b :: acc )) (func a)
    ) ( list, [] )
```

### Step 4.2: `Compiler.LocalOpt.Erased.Names` — Add `loop`, Rewrite `traverse`

Same pattern. The `Tracker` type here has 3 state fields (`uid`, `deps`, `fields`) instead
of 4:

**Add `loop`:**
```elm
import Control.Loop exposing (Step(..))

loop : (state -> Tracker (Step state a)) -> state -> Tracker a
loop callback loopState =
    Tracker (\n d f ->
        loopHelper callback loopState n d f
    )


loopHelper : (state -> Tracker (Step state a)) -> state -> Int -> Deps -> Fields -> TResult a
loopHelper callback loopState n d f =
    case callback loopState of
        Tracker k ->
            case k n d f of
                TResult props (Loop newState) ->
                    loopHelper callback newState props.uid props.deps props.fields

                TResult props (Done a) ->
                    TResult props a
```

**Rewrite `traverse`:**
```elm
traverse : (a -> Tracker b) -> List a -> Tracker (List b)
traverse func list =
    loop (\( remaining, acc ) ->
        case remaining of
            [] -> pure (Done (List.reverse acc))
            a :: rest -> map (\b -> Loop ( rest, b :: acc )) (func a)
    ) ( list, [] )
```

### Step 4.3: `Compiler.LocalOpt.Erased.Names.mapTraverse`

**Rewrite using `loop`:**
```elm
mapTraverse : (k -> comparable) -> (k -> k -> Order) -> (a -> Tracker b) -> Dict comparable k a -> Tracker (Dict comparable k b)
mapTraverse toComparable keyComparison func dict =
    loop (\( pairs, acc ) ->
        case pairs of
            [] -> pure (Done acc)
            ( k, a ) :: rest ->
                map (\b -> Loop ( rest, Dict.insert toComparable k b acc )) (func a)
    ) ( Dict.toList keyComparison dict, Dict.empty )
```

---

## Phase 5 (Low Priority): Unify.elm Recursive `andThen`

### `unifyArgs` and `unifyAliasArgs`

These are recursive functions that `IO.andThen` at each step, with chain depth = number of
type arguments. Typically 0–5 args, so overflow is unlikely in practice.

**Skip unless profiling reveals a problem.** If needed later, convert to `IO.loop` with an
accumulator tracking `( vars, remainingArgs1, remainingArgs2, allOk )`.

---

## Implementation Order

| Step | Priority | File(s) | Change |
|------|----------|---------|--------|
| 0.1 | P0 | `Control/Loop.elm` (new) | Shared `Step` type |
| 0.2 | P0 | `System/TypeCheck/IO.elm` | Re-export `Step` from `Control.Loop` |
| 1.1 | P0 | `Compiler/Type/Constrain/Typed/Module.elm` | `constrainDeclsWithVarsHelp` → `IO.loop` |
| 1.2 | P0 | `Compiler/Type/Constrain/Erased/Module.elm` | `constrainDeclsHelp` → `IO.loop` |
| 2.1 | P1 | `System/TypeCheck/IO.elm` | `traverseList`/`mapM` → `IO.loop` |
| 2.2 | P1 | `System/TypeCheck/IO.elm` | `foldMDict` → `IO.loop` |
| 2.3 | P1 | `Compiler/Type/Type.elm` | `toCanTypeBatch` → use `IO.foldM` |
| 3.1 | P2 | `Control/Monad/State/TypeCheck/Strict.elm` | `traverseList` → unwrap to `IO.loop` |
| 3.2 | P2 | `Control/Monad/State/TypeCheck/Strict.elm` | `traverseMapWithKey` → unwrap to `IO.loop` |
| 4.1 | P3 | `Compiler/LocalOpt/Typed/Names.elm` | Add `loop`, rewrite `traverse` |
| 4.2 | P3 | `Compiler/LocalOpt/Erased/Names.elm` | Add `loop`, rewrite `traverse` |
| 4.3 | P3 | `Compiler/LocalOpt/Erased/Names.elm` | Rewrite `mapTraverse` using `loop` |

## Validation

After each phase:
1. Run frontend tests: `cd /work/compiler && npx elm-test-rs --project build-xhr --fuzz 1`
2. Bootstrap stages 1–4 will be run manually later to verify fixed-point.
3. After all phases: retry Stage 5 with 5-minute timeout.

After P0+P1 are complete, Stage 5 should get past the module that was crashing (module 55).
Full completion of Stage 5 may require additional work (the profiling showed bytes
encode/decode as the main time sink, but not a stack overflow source).

## Relationship to Existing Plan

`/work/plans/state-monad-stack-safety.md` describes a more ambitious DSL-based refactoring of
the constraint generation code. This plan is a **targeted, minimal fix** that addresses the
same root cause (deep `andThen` chains) but with much smaller scope:

- One small new module (`Control.Loop` — 5 lines)
- No new DSL types or interpreters
- No changes to `IO` core types
- Each fix is a local rewrite of one function
- The DSL plan can still be pursued later for constraint generation specifically

The two plans are complementary, not conflicting. This plan fixes the immediate Stage 5 crash;
the DSL plan provides deeper architectural improvement for constraint generation specifically.
