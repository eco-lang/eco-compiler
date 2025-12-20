# State Monad Stack Safety Refactoring Plan

Based on design document: `/work/design_docs/state-monad-refactor.md`

## Problem Statement

The type constraint generation code uses deeply nested `IO.andThen` closures that cause JavaScript stack overflow when processing moderately complex expressions (e.g., binop chains of length 3+ with nested if-expressions).

## Solution Overview

Keep `System.TypeCheck.IO` as the **single core primitive IO monad** (low-level state + primitive "effects"). Build **two higher-level DSLs** on top:

1. **Constraint-generation DSL** (`Compiler.Type.Constrain.Program.Prog`) - walks expressions/patterns and builds constraints without deep IO call chains
2. **Solver/unifier DSL** - already exists: walks the `Constraint` tree (`CTrue`, `CAnd`, `CLet`, etc.) and performs unification via `Solve.solve` + `Unify.Unify`

Both DSLs interpret down into `System.TypeCheck.IO.IO`.

The constraint-generation DSL:
1. Represents constraint-building steps as **data** (not closures)
2. Is interpreted by a **tail-recursive loop** using `IO.loop`
3. Keeps an **explicit continuation stack** instead of growing the JS call stack

**Key principle**: Leave `System.TypeCheck.IO` completely unchanged. All changes are at a higher level.

---

## Phase 1: Create the DSL Module

**New file: `src/Compiler/Type/Constrain/Program.elm`**

### 1.1 Define the Program Type

```elm
module Compiler.Type.Constrain.Program exposing
    ( Prog
    , pure, map, andThen
    , run, runPattern
    , opMkFlexVar
    , opConstrainExpr
    , opConstrainPattern
    )

type Prog a
    = Done a
    | Step (Instr a)

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
    | Bind (Prog ()) (() -> Prog a)  -- Note: simplified for Elm's type system
    -- For intermediate values, we use continuation-passing in each instruction's `k` field
```

**Implementation Note on Types:**
Elm doesn't have existential types, so `Bind` is simplified. In practice, we chain via the `k` continuations in each instruction. The `Bind` constructor is primarily for sequencing `()` results (like after `emitConstraint`). For value-carrying chains, use the `k` continuations directly.

Notes:
- `MkFlexVar` encapsulates `Type.mkFlexVar` allocation
- `ConstrainExpr` wraps "constrain this expression with RTV + expectation"
- `ConstrainPattern` wraps `Pattern.add`
- `Bind` is monadic bind reified as data

### 1.2 Define Monad Operations

```elm
pure : a -> Prog a
pure a = Done a

map : (a -> b) -> Prog a -> Prog b
map f prog =
    case prog of
        Done a -> Done (f a)
        Step instr -> Step (mapInstr f instr)

-- andThen is achieved by using continuations in each instruction
-- For example: opMkFlexVar |> andThen (\var -> ...) becomes:
--   Step (MkFlexVar (\var -> ...))
-- The smart constructors handle this pattern

andThen : (a -> Prog b) -> Prog a -> Prog b
andThen k prog =
    case prog of
        Done a -> k a
        Step instr -> Step (bindInstr k instr)

-- Helper to map over instruction continuations
mapInstr : (a -> b) -> Instr a -> Instr b
mapInstr f instr =
    case instr of
        MkFlexVar k -> MkFlexVar (k >> map f)
        ConstrainExpr r -> ConstrainExpr { r | k = r.k >> map f }
        ConstrainPattern r -> ConstrainPattern { r | k = r.k >> map f }
        Bind p k -> Bind p (k >> map f)

bindInstr : (a -> Prog b) -> Instr a -> Instr b
bindInstr f instr =
    case instr of
        MkFlexVar k -> MkFlexVar (k >> andThen f)
        ConstrainExpr r -> ConstrainExpr { r | k = r.k >> andThen f }
        ConstrainPattern r -> ConstrainPattern { r | k = r.k >> andThen f }
        Bind p k -> Bind p (k >> andThen f)
```

**Note:** This implementation recomposes continuations. The interpreter flattens these into an explicit stack.

### 1.3 Define Smart Constructors

```elm
opMkFlexVar : Prog IO.Variable
opMkFlexVar = Step (MkFlexVar Done)

-- Note: For Type.mkFlexNumber, we can either:
-- 1. Add a separate MkFlexNumber instruction, or
-- 2. Handle it in constrainStep since it's only used for Int literals
-- Option 2 is simpler since mkFlexNumber is just mkFlexVar + setAtomicType

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

### 1.4 Define the Tail-Recursive Interpreter

```elm
run : Prog a -> IO a
run program0 =
    IO.loop step ( program0, [] )

type alias Frame a = a -> Prog a

step : ( Prog a, List (Frame a) ) -> IO (IO.Step ( Prog a, List (Frame a) ) a)
step ( program, stack ) =
    case program of
        Done value ->
            case stack of
                [] ->
                    IO.pure (IO.Done value)
                frame :: rest ->
                    IO.pure (IO.Loop ( frame value, rest ))

        Step instr ->
            case instr of
                Bind sub k ->
                    IO.pure (IO.Loop ( sub, k :: stack ))

                MkFlexVar k ->
                    Type.mkFlexVar
                        |> IO.map (\var -> IO.Loop ( k var, stack ))

                ConstrainExpr { rtv, expr, expected, k } ->
                    Compiler.Type.Constrain.Expression.constrainStep rtv expr expected
                        |> IO.map (\con -> IO.Loop ( k con, stack ))

                ConstrainPattern { pattern, expected, k } ->
                    -- With PatternProg (Option B), Pattern.add uses internal DSL
                    -- Always starts with empty state for expression-level pattern constraints
                    Pattern.add pattern expected Pattern.emptyState
                        |> IO.map (\state -> IO.Loop ( k state, stack ))
```

**Key property**: Only one recursive path through `IO.loop`. All nested work is handled via the explicit `stack`, not the JS call stack.

### 1.5 Pattern DSL Decision

Two options for handling patterns:

**Option A: Reuse `Prog` for patterns**
- Add extra constructors (e.g., `PatternMkFlexVar`, `PatternBind`)
- Create `runPattern : Prog State -> IO State`

**Option B: Separate `PatternProg` type** (chosen)
- Create a separate DSL type in `Pattern` module with its own interpreter
- Cleaner separation of concerns
- Parameterized over state type `s` to handle both `State` and `(State, NodeIdState)`
- Includes state manipulation primitives (`PModify`, `PGet`) not needed for expressions

**Decision**: Use Option B. The `PatternProg` type is better suited because:
1. Patterns need state threading (`State` or `WithIdsState`) that expressions don't
2. Pattern operations modify state in place rather than returning constraints
3. The parameterized type `PatternProg s a` cleanly handles both `add` and `addWithIds` variants

**Relationship between DSLs:**
- `Prog` (in `Program.elm`) - for expression constraints, has `ConstrainPattern` instruction
- `PatternProg` (internal to `Pattern.elm`) - for pattern constraints
- `ConstrainPattern` instruction calls `Pattern.add` which internally uses `PatternProg`
- This layering keeps PatternProg encapsulated; Expression.elm doesn't know about it

---

## Phase 2: Refactor Expression.elm

**File: `src/Compiler/Type/Constrain/Expression.elm`**

### 2.1 Add `constrainStep` - One-Step Non-Recursive Helper

```elm
constrainStep :
    RigidTypeVar
    -> Can.Expr
    -> E.Expected Type
    -> IO Constraint
constrainStep rtv ((A.At region exprInfo) as expr) expected =
    case exprInfo.node of
        -- Simple leaf cases: return IO directly
        Can.VarLocal name ->
            IO.pure (CLocal region name expected)

        Can.VarTopLevel _ name ->
            IO.pure (CLocal region name expected)

        Can.VarKernel _ _ ->
            IO.pure CTrue

        Can.VarForeign _ name annotation ->
            IO.pure (CForeign region name annotation expected)

        Can.Int _ ->
            Type.mkFlexNumber
                |> IO.map (\var ->
                    Type.exists [ var ] (CEqual region E.Number (VarN var) expected))

        Can.Float _ ->
            Type.mkFlexVar
                |> IO.map (\var ->
                    Type.exists [ var ] (CEqual region E.Float (VarN var) expected))

        -- Complex recursive cases: delegate to DSL builders
        Can.Binop op _ _ annotation leftExpr rightExpr ->
            constrainBinopProg rtv region op annotation leftExpr rightExpr expected
                |> Program.run

        Can.If branches finalExpr ->
            constrainIfProg rtv region branches finalExpr expected
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

        Can.Lambda args body ->
            constrainLambdaProg rtv region args body expected
                |> Program.run

        Can.Call func args ->
            constrainCallProg rtv region func args expected
                |> Program.run

        Can.Case subject branches ->
            constrainCaseProg rtv region subject branches expected
                |> Program.run

        Can.Let def body ->
            constrainLetProg rtv region def body expected
                |> Program.run

        Can.LetRec defs body ->
            constrainLetRecProg rtv region defs body expected
                |> Program.run

        Can.Destruct pattern expr body ->
            constrainDestructProg rtv region pattern expr body expected
                |> Program.run

        -- ... etc for each case
```

The idea:
- `constrainStep` **does at most one layer of IO** and never recurses
- Simple leaf cases return `IO.pure ...` directly
- Complex cases delegate to `...Prog` helpers that use the DSL

### 2.2 Create `...Prog` Builders for Each Recursive Case

**Example: `constrainBinopProg`**

```elm
constrainBinopProg :
    RigidTypeVar -> A.Region -> Can.Binop
    -> Can.Expr -> Can.Expr -> E.Expected Type
    -> Program.Prog Constraint
constrainBinopProg rtv region op leftExpr rightExpr expected =
    Program.opMkFlexVar
        |> Program.andThen (\leftVar ->
            Program.opMkFlexVar
                |> Program.andThen (\rightVar ->
                    Program.opMkFlexVar
                        |> Program.andThen (\answerVar ->
                            let
                                leftType = VarN leftVar
                                rightType = VarN rightVar
                                ansType = VarN answerVar
                            in
                            -- Recursive calls through DSL, not IO:
                            Program.opConstrainExpr rtv leftExpr (E.NoExpectation leftType)
                                |> Program.andThen (\leftCon ->
                                    Program.opConstrainExpr rtv rightExpr (E.NoExpectation rightType)
                                        |> Program.map (\rightCon ->
                                            -- Build final constraint purely:
                                            let
                                                binopCon = ... -- same as before
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

**Key**: This purely builds a `Prog Constraint` value. No IO occurs during construction.

Then `constrainStep` calls `constrainBinopProg ... |> Program.run`, which:
- Uses `MkFlexVar` instructions to call `Type.mkFlexVar` in small, flat IO steps
- Uses `ConstrainExpr` to delegate recursive sub-expressions back into `constrainStep` in a loop

### 2.3 Functions to Convert

| Original Function | New Builder | Notes |
|-------------------|-------------|-------|
| `constrainBinop` | `constrainBinopProg` | 5 nested andThens |
| `constrainIf` | `constrainIfProg` | Major nesting contributor |
| `constrainTuple` | `constrainTupleProg` | Multi-step IO chains |
| `constrainList` | `constrainListProg` | Traversal pattern |
| `constrainRecord` | `constrainRecordProg` | Field traversal |
| `constrainUpdate` | `constrainUpdateProg` | Nested chains |
| `constrainDestruct` | `constrainDestructProg` | Pattern integration |
| `constrainLambda` | `constrainLambdaProg` | Arg traversal |
| `constrainCall` | `constrainCallProg` | Arg traversal |
| `constrainCase` | `constrainCaseProg` | Branch traversal |
| `constrainLet` | `constrainLetProg` | Binding + body |
| `constrainLetRec` | `constrainLetRecProg` | Recursive bindings |

Plus all `*WithIds` variants:
- `constrainWithIds` → `constrainWithIdsProg`
- `constrainDefWithIds` → `constrainDefWithIdsProg`
- `constrainRecursiveDefsWithIds` → `constrainRecursiveDefsWithIdsProg`

### 2.4 Entry Point Functions

The main entry points (`constrainDef`, `constrainRecursiveDefs`) should be thin wrappers:

```elm
constrainDef : RigidTypeVar -> Can.Def -> IO Constraint
constrainDef rtv def =
    constrainDefProg rtv def
        |> Program.run

constrainDefProg : RigidTypeVar -> Can.Def -> Program.Prog Constraint
constrainDefProg rtv (Can.Def _ patterns body _) =
    -- Build pattern constraints, then body constraint
    -- Use Program.opConstrainExpr for body
    -- Use Program.opConstrainPattern for each pattern
    ...
```

This ensures even the top-level definition constraints go through the DSL.

### 2.5 Strategy for each function:
1. Extract core logic into a **pure** `...Prog` builder returning `Prog Constraint` or `Prog (Constraint, ExprIdState)`
2. Replace original function with thin wrapper: `...Prog |> Program.run`
3. Inside `...Prog`, replace recursive `constrain` calls with `Program.opConstrainExpr`
4. Replace `Type.mkFlexVar` chains with `Program.opMkFlexVar`

---

## Phase 3: Refactor Pattern.elm with PatternProg DSL

**File: `src/Compiler/Type/Constrain/Pattern.elm`**

### 3.1 Current Pattern Module Structure

Today, the module exposes:

```elm
type State
    = State Header (List IO.Variable) (List Type.Constraint)

type alias Header =
    Dict String Name.Name (A.Located Type)

add : Can.Pattern -> E.PExpected Type -> State -> IO State
addWithIds : Can.Pattern -> E.PExpected Type -> State -> NodeIds.NodeIdState -> IO (State, NodeIds.NodeIdState)
```

Functions like `addTuple` use nested `IO.andThen` and `Type.mkFlexVar` chains that blow the JS stack.

### 3.2 Define the PatternProg DSL Type

Add an **internal** DSL parameterized over the pattern-state type `s`:

```elm
-- INTERNAL DSL (not exposed)

type PatternProg s a
    = PDone a
    | PBind (PatternProg s x) (x -> PatternProg s a)
    | PIO (IO x) (x -> PatternProg s a)
    | PModify (s -> s) (PatternProg s a)
    | PGet (s -> PatternProg s a)
```

Intuition:
- `PDone a` - computation complete with value `a`
- `PBind sub k` - monadic bind: run `sub`, then continue with `k`
- `PIO io k` - run one IO action, then continue with its result
- `PModify f next` - apply `f` to the state, then continue
- `PGet k` - read the state and feed it to `k`

The type parameter `s` will be:
- `s = State` for the plain `add` API
- `s = (State, NodeIds.NodeIdState)` for `addWithIds`

### 3.3 Define the Tail-Recursive Interpreter

```elm
runProg : PatternProg s a -> s -> IO ( a, s )
runProg prog0 s0 =
    IO.loop step ( prog0, [], s0 )


type alias Frame s a =
    a -> PatternProg s a


step :
    ( PatternProg s a, List (Frame s a), s )
    -> IO (IO.Step ( PatternProg s a, List (Frame s a), s ) ( a, s ))
step ( prog, stack, s ) =
    case prog of
        PDone value ->
            case stack of
                [] ->
                    IO.pure (IO.Done ( value, s ))

                k :: rest ->
                    IO.pure (IO.Loop ( k value, rest, s ))

        PBind sub k ->
            IO.pure (IO.Loop ( sub, k :: stack, s ))

        PIO io k ->
            io
                |> IO.map (\x -> IO.Loop ( k x, stack, s ))

        PModify f next ->
            IO.pure (IO.Loop ( next, stack, f s ))

        PGet k ->
            IO.pure (IO.Loop ( k s, stack, s ))
```

Key properties:
- Only recursion is via `IO.loop` (tail-recursive)
- Pattern recursion expressed as `PatternProg` value shape, not `IO.andThen` chains
- Each `PIO` executes one IO action as a single step

### 3.4 Define Convenience Combinators

```elm
pureP : a -> PatternProg s a
pureP = PDone

andThenP : (a -> PatternProg s b) -> PatternProg s a -> PatternProg s b
andThenP k p = PBind p k

mapP : (a -> b) -> PatternProg s a -> PatternProg s b
mapP f p = andThenP (f >> pureP) p

liftIO : IO x -> PatternProg s x
liftIO io = PIO io PDone

get : PatternProg s s
get = PGet PDone

modify : (s -> s) -> PatternProg s ()
modify f = PModify f (PDone ())
```

### 3.5 Define State-Specific Helpers

For `State`:

```elm
-- Initial empty state (already exists in Pattern.elm)
emptyState : State
emptyState = State Dict.empty [] []

emitConstraint : Type.Constraint -> PatternProg State ()
emitConstraint con =
    modify (\(State headers vars revCons) ->
        State headers vars (con :: revCons))

addVarP : IO.Variable -> PatternProg State ()
addVarP var =
    modify (\(State headers vars revCons) ->
        State headers (var :: vars) revCons)

addHeaderP : A.Region -> Name.Name -> E.PExpected Type -> PatternProg State ()
addHeaderP region name expectation =
    modify (addToHeaders region name expectation)

mkFlexVarP : PatternProg s IO.Variable
mkFlexVarP = liftIO Type.mkFlexVar
```

For `WithIdsState = (State, NodeIds.NodeIdState)`:

```elm
emitConstraintIds : Type.Constraint -> PatternProg WithIdsState ()
addVarIds : IO.Variable -> PatternProg WithIdsState ()
addHeaderIds : A.Region -> Name.Name -> E.PExpected Type -> PatternProg WithIdsState ()
recordNodeVarIds : Int -> IO.Variable -> PatternProg WithIdsState ()
```

### 3.6 Rewrite `add` Using PatternProg

```elm
addProg : Can.Pattern -> E.PExpected Type -> PatternProg State ()
addProg (A.At region patternInfo) expectation =
    case patternInfo.node of
        Can.PAnything ->
            pureP ()

        Can.PVar name ->
            addHeaderP region name expectation

        Can.PAlias realPattern name ->
            addHeaderP region name expectation
                |> andThenP (\_ -> addProg realPattern expectation)

        Can.PUnit ->
            emitConstraint (Type.CPattern region E.PUnit Type.UnitN expectation)

        Can.PTuple a b cs ->
            addTupleProg region a b cs expectation

        Can.PList patterns ->
            addListProg region patterns expectation

        Can.PCons headPattern tailPattern ->
            addConsProg region headPattern tailPattern expectation

        Can.PRecord fields ->
            addRecordProg region fields expectation

        Can.PCtor { home, type_, union, name, args } ->
            addCtorProg region home type_ union name args expectation


-- Public API unchanged:
add : Can.Pattern -> E.PExpected Type -> State -> IO State
add pattern expectation state0 =
    runProg (addProg pattern expectation) state0
        |> IO.map Tuple.second
```

### 3.7 Example: `addTupleProg`

Before (nested IO):
```elm
addTuple region a b cs expectation state =
    Type.mkFlexVar
        |> IO.andThen (\aVar ->
            Type.mkFlexVar
                |> IO.andThen (\bVar ->
                    -- ... deeply nested
```

After (PatternProg):
```elm
addTupleProg : A.Region -> Can.Pattern -> Can.Pattern -> List Can.Pattern -> E.PExpected Type -> PatternProg State ()
addTupleProg region a b cs expectation =
    mkFlexVarP
        |> andThenP (\aVar ->
            mkFlexVarP
                |> andThenP (\bVar ->
                    let
                        aType = Type.VarN aVar
                        bType = Type.VarN bVar
                    in
                    simpleAddProg a aType
                        |> andThenP (\_ -> simpleAddProg b bType)
                        |> andThenP (\_ ->
                            foldCsProg cs []
                                |> andThenP (\cVars ->
                                    emitConstraint (Type.CPattern region E.PTuple tupleType expectation)
                                        |> andThenP (\_ -> addVarsP (aVar :: bVar :: cVars))
                                )
                        )
                )
        )

foldCsProg : List Can.Pattern -> List IO.Variable -> PatternProg State (List IO.Variable)
foldCsProg cs acc =
    case cs of
        [] -> pureP (List.reverse acc)
        c :: rest ->
            mkFlexVarP
                |> andThenP (\cVar ->
                    simpleAddProg c (Type.VarN cVar)
                        |> andThenP (\_ -> foldCsProg rest (cVar :: acc))
                )
```

Key differences:
- All recursion over `cs` is in `foldCsProg` as DSL program, not nested IO
- `Type.mkFlexVar` called via `liftIO` in isolated `PIO` instructions
- State updates via `emitConstraint` / `addVarP` / `addHeaderP` using `PModify`

### 3.8 Functions to Convert

| Original Function | New Builder | Notes |
|-------------------|-------------|-------|
| `add` | `addProg` | Main entry point |
| `addTuple` | `addTupleProg` | 2+ element tuples |
| `addList` | `addListProg` | List patterns |
| `addCons` | `addConsProg` | Cons patterns |
| `addRecord` | `addRecordProg` | Record patterns |
| `addCtor` | `addCtorProg` | Constructor patterns (calls `Instantiate.fromSrcType`) |
| `addAlias` | (inline in `addProg`) | Pattern alias |

Plus all `*WithIds` variants using `PatternProg WithIdsState`:
- `addWithIds` → `addWithIdsProg`
- `addTupleWithIds` → `addTupleWithIdsProg`
- etc.

### 3.9 Effect on Callers

External APIs remain unchanged:
- `add : Can.Pattern -> E.PExpected Type -> State -> IO State`
- `addWithIds : Can.Pattern -> E.PExpected Type -> State -> NodeIdState -> IO (State, NodeIdState)`

Call sites in `Expression.elm` (e.g., `constrainDestruct`) and `Module.elm` do **not** need changes. They automatically benefit from the stack-safe implementation

---

## Phase 4: Refactor Module.elm

**File: `src/Compiler/Type/Constrain/Module.elm`**

### 4.1 Public API (Unchanged)

```elm
constrain : Can.Module -> IO Constraint
constrainWithIds : Can.Module -> IO ( Constraint, NodeIds.NodeVarMap )
```

These signatures remain the same.

### 4.2 Internal Changes

The module uses two patterns for declaration constraints:

**Pattern 1: CPS-style in `constrainDeclsHelp`**
```elm
constrainDeclsHelp : Can.Decls -> Constraint -> (IO Constraint -> IO Constraint) -> IO Constraint
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

This CPS pattern is already reasonably flat. No changes needed here because `Expr.constrainDef` / `Expr.constrainRecursiveDefs` will internally use the DSL, eliminating deep IO chaining at that level.

**Pattern 2: Direct `IO.andThen` in `constrainDeclsWithVarsHelp`**
```elm
constrainDeclsWithVarsHelp decls finalConstraint state =
    case decls of
        Can.Declare def otherDecls ->
            constrainDeclsWithVarsHelp otherDecls finalConstraint state
                |> IO.andThen (\( constraint, s ) ->
                    Expr.constrainDefWithIds Dict.empty def constraint s
                )
        -- ...
```

Again, `Expr.constrainDefWithIds` will use the DSL internally. The module-level chaining is shallow.

### 4.3 Effect Manager Helpers - Candidate for DSL

The `constrainEffects` function has **7 deeply nested `mkFlexVar` calls**:

```elm
constrainEffects home r0 r1 r2 manager =
    mkFlexVar
        |> IO.andThen (\s0 ->
            mkFlexVar
                |> IO.andThen (\s1 ->
                    mkFlexVar
                        |> IO.andThen (\s2 ->
                            mkFlexVar
                                |> IO.andThen (\m1 ->
                                    mkFlexVar
                                        |> IO.andThen (\m2 ->
                                            mkFlexVar
                                                |> IO.andThen (\sm1 ->
                                                    mkFlexVar
                                                        |> IO.andThen (\sm2 ->
                                                            -- ... deep nesting
```

This is exactly the pattern the DSL is designed to fix. Convert to:

```elm
constrainEffectsProg : IO.Canonical -> A.Region -> A.Region -> A.Region -> Can.Manager -> Program.Prog Constraint
constrainEffectsProg home r0 r1 r2 manager =
    Program.opMkFlexVar
        |> Program.andThen (\s0 ->
            Program.opMkFlexVar
                |> Program.andThen (\s1 ->
                    -- ... flat DSL program
                )
        )

constrainEffects : IO.Canonical -> A.Region -> A.Region -> A.Region -> Can.Manager -> IO Constraint
constrainEffects home r0 r1 r2 manager =
    constrainEffectsProg home r0 r1 r2 manager
        |> Program.run
```

Similarly, `checkMap` and `letPort` have 2-level nesting that could be converted for consistency.

### 4.4 Summary of Module Changes

| Function | Change |
|----------|--------|
| `constrain` | No change (API) |
| `constrainWithIds` | No change (API) |
| `constrainDecls` / `constrainDeclsHelp` | No change (CPS already flat) |
| `constrainDeclsWithVars` / `constrainDeclsWithVarsHelp` | No change (uses Expression DSL internally) |
| `constrainEffects` | Convert to `constrainEffectsProg` + DSL |
| `letPort` | Optional: convert to DSL (2-level nesting) |
| `letCmd` / `letSub` | No change (1-level nesting) |
| `checkMap` | Optional: convert to DSL (2-level nesting) |

---

## Phase 5: Solver Side (No Mandatory Changes)

**Files**: `Compiler/Type/Solve.elm`, `Compiler/Type/Unify.elm`

### 5.1 Current Architecture

The solver already has good structure:

**Constraint AST** (`Compiler.Type.Type.Constraint`):
- `CTrue` - always satisfied
- `CAnd` - conjunction of constraints
- `CLet` - let-binding with generalization
- `CLocal` - local variable reference
- `CForeign` - foreign/imported type
- `CEqual` - type equality
- `CPattern` - pattern type constraint
- `CSaveTheEnvironment` - marker for environment capture

```elm
solve : Env -> Int -> Pools -> State -> Constraint -> IO State
solve env rank pools state constraint =
    IO.loop solveHelp ( ( env, rank ), ( pools, state ), ( constraint, identity ) )
```

where `solveHelp` inspects one `Constraint` and returns either `Loop` (continue) or `Done` (finish).

The unification system uses a CPS-style DSL:
```elm
type Unify a = Unify (List IO.Variable -> IO (Result UnifyErr (UnifyOk a)))
```

with its own `map`, `pure`, and `andThen`.

### 5.2 Conceptual Alignment (Optional)

This is already "very close" to a DSL on top of core IO. You can optionally:

1. Introduce `Compiler.Type.Solve.Program` module that names the patterns:
   - `type alias SolveProg a = ( (Env, Int), (Pools, State), (Constraint, IO State -> IO State) )`
   - `step : SolveProg a -> IO (IO.Step SolveProg a)` (already there as `solveHelp`)
   - `run : Constraint -> IO State` (already there as `solve`)

2. Document the constraint tree + `solve`/`solveHelp` + `Unify` as the "solver DSL"

At this stage, the actual stack overflow is in constraint **generation**, not the solver. Solver refactoring is not urgent.

---

## What NOT to Change

Per design document, these remain unchanged:

**Core IO Layer:**
- `System.TypeCheck.IO` - all of it:
  - `type alias IO a = State -> ( State, a )` and `State`
  - `IO.pure`, `IO.map`, `IO.andThen`, `IO.loop`, etc.

**Low-Level Data Structures:**
- `Data.IORef` - mutable references
- `Compiler.Type.UnionFind` - union-find for type variables
- `Data.Vector`, `Data.Vector.Mutable` - array operations

**Type Operations:**
- `Compiler.Type.Type` - all operations:
  - `mkFlexVar`, `mkFlexNumber`
  - `toAnnotation`, `toCanType`
  - Type constructors (`VarN`, `FunN`, `AppN`, etc.)

**Solver:**
- `Compiler.Type.Solve` main loop (`solve`, `solveHelp`, `IO.loop`)
- `Compiler.Type.Unify.Unify` CPS structure

**Other:**
- `Compiler.Type.Instantiate`
- `Compiler.Type.Error`

This keeps the low-level store and union-find unchanged, avoiding a huge invasive rewrite. Our changes are *above* this level.

---

## Impacted Modules Summary

### New Module

- **`Compiler.Type.Constrain.Program`**
  - Defines `Prog`, `Instr`, monad ops (`pure`, `map`, `andThen`)
  - Defines `run`, possibly `runPattern`
  - Smart constructors: `opMkFlexVar`, `opConstrainExpr`, `opConstrainPattern`

### Modified Modules: Constraint Generation

1. **`Compiler.Type.Constrain.Expression`**
   - Add `constrainStep : RigidTypeVar -> Can.Expr -> E.Expected Type -> IO Constraint`
   - For each recursive helper, extract `...Prog` builder returning `Prog Constraint`
   - Implement original functions as `...Prog |> Program.run`
   - Replace recursive `constrain` calls with `Program.opConstrainExpr`
   - Functions: `constrainBinop`, `constrainIf`, `constrainTuple`, `constrainRecord`, `constrainUpdate`, `constrainDestruct`, `constrainLambda`, `constrainCall`, `constrainCase`, `constrainLet`, `constrainLetRec`
   - Plus all `WithIds` variants

2. **`Compiler.Type.Constrain.Pattern`**
   - Add internal `PatternProg s a` DSL type (parameterized over state)
   - Add `runProg` interpreter using `IO.loop`
   - Add combinators: `pureP`, `andThenP`, `mapP`, `liftIO`, `get`, `modify`
   - Add state helpers: `emitConstraint`, `addVarP`, `addHeaderP`, `mkFlexVarP`
   - Add `WithIdsState` helpers for node ID tracking
   - Convert functions to `...Prog` builders:
     - `add` → `addProg` (entry point)
     - `addTuple` → `addTupleProg`
     - `addList` → `addListProg`
     - `addCons` → `addConsProg`
     - `addRecord` → `addRecordProg`
     - `addCtor` → `addCtorProg`
   - Plus all `*WithIds` variants using `PatternProg WithIdsState`
   - External APIs (`add`, `addWithIds`) remain unchanged

3. **`Compiler.Type.Constrain.Module`**
   - No signature changes
   - Convert `constrainEffects` to use DSL (7-level nesting)
   - Optional: convert `letPort`, `checkMap` for consistency
   - Internal calls to `Expr.constrainDef` / `Expr.constrainRecursiveDefs` benefit from DSL automatically

### "With IDs" Tracking Functions

All node ID tracking variants follow the same DSL pattern but keep their external IO signatures:

**In `Compiler.Type.Constrain.Module`:**
- `constrainWithIds` - module-level entry point
- `constrainDeclsWithVars` / `constrainDeclsWithVarsHelp` - declaration traversal

**In `Compiler.Type.Constrain.Expression`:**
- `constrainWithIds` - expression entry point
- `constrainDefWithIds` - definition with ID tracking
- `constrainRecursiveDefsWithIds` - recursive definitions with ID tracking
- All `...WithIdsProg` variants returning `Prog (Constraint, ExprIdState)`

**In `Compiler.Type.Constrain.Pattern`:**
- `addWithIds` - pattern entry point
- `addTupleWithIds`, `addListWithIds`, `addCtorWithIds`, etc.
- All use `PatternProg WithIdsState` where `WithIdsState = (State, NodeIds.NodeIdState)`

### Solver Side (No Mandatory Changes)

- `Compiler.Type.Solve` - leave as is, already uses `IO.loop`
- `Compiler.Type.Unify` - already uses CPS, no change

---

## Implementation Prerequisites

Before starting implementation, read and understand:

1. **`src/Compiler/Type/Constrain/Expression.elm`** - Identify all recursive `constrain*` functions and their `IO.andThen` chains
2. **`src/Compiler/Type/Constrain/Pattern.elm`** - Identify all recursive `add*` functions
3. **`src/Compiler/Type/Constrain/Module.elm`** - Understand how module-level constraints are assembled
4. **`src/System/TypeCheck/IO.elm`** - Understand `IO.loop` and `IO.Step` for the interpreter

### Module Dependency Resolution

**Potential circular dependency issue:**
- `Program.elm` interpreter calls `Expression.constrainStep` and `Pattern.add`
- `Expression.elm` uses `Program.Prog` and `Program.run`
- `Pattern.elm` uses `PatternProg` internally (no external dependency)

**Solution:** Structure imports carefully:
1. `Program.elm` imports `Expression` and `Pattern` (for interpreter dispatch)
2. `Expression.elm` imports `Program` (for DSL building)
3. `Pattern.elm` has self-contained `PatternProg` (no circular dependency)

The key insight: `constrainStep` is the **boundary** between the interpreter and DSL builders. The interpreter calls `constrainStep` (IO function), and `constrainStep` may call `Program.run` for complex cases.

### Complete Expression Cases

All cases that `constrainStep` must handle (check actual file for exact constructors):

**Leaf cases (return IO directly):**
- `VarLocal`, `VarTopLevel`, `VarKernel`, `VarForeign`
- `Int`, `Float`, `Chr`, `Str`
- `Unit`
- `Accessor` (field accessor function)

**Recursive cases (delegate to `...Prog` builder):**
- `Binop` - binary operators
- `If` - if-then-else chains
- `Tuple` - tuple construction
- `List` - list literals
- `Record` - record construction
- `Update` - record update
- `Lambda` - function literals
- `Call` - function application
- `Case` - pattern matching
- `Let` - let bindings
- `LetRec` - recursive let bindings
- `Destruct` - pattern destructuring
- `Negate` - numeric negation
- `Shader` - WebGL shaders (if applicable)

---

## Rollout Strategy

### Step 1: Introduce DSL Module
Create `Compiler.Type.Constrain.Program` with `Prog`, `Instr`, monad ops, and `run`. No callers yet.

### Step 2: Convert First Hot Path (Binop)
1. Implement `constrainBinopProg` using `Prog`
2. Add `constrainStep` with binop case calling `constrainBinopProg |> Program.run`
3. Run fuzz tests for binop chains and nested ifs to verify stack behavior

### Step 3: Convert Remaining Recursive Cases
- `constrainIfProg` (major nesting contributor)
- `constrainTupleProg`, `constrainListProg`, `constrainRecordProg`
- `constrainUpdateProg`, `constrainDestructProg`
- `constrainLambdaProg`, `constrainCallProg`, `constrainCaseProg`
- `constrainLetProg`, `constrainLetRecProg`

### Step 4: Convert Pattern Module
- Add internal `PatternProg` DSL type and `runProg` interpreter
- Add convenience combinators (`pureP`, `andThenP`, `liftIO`, `modify`, etc.)
- Convert `add` to use `addProg` internally
- Add `...Prog` builders for `addTuple`, `addList`, `addCons`, `addRecord`, `addCtor`
- Verify `constrainDestructProg` works correctly with new pattern implementation

### Step 5: Convert WithIds Variants
Apply same pattern to all `*WithIds` functions in both Expression and Pattern.

### Step 6: Convert Module.elm Hot Paths
- Convert `constrainEffects` to use DSL
- Optional: convert `letPort`, `checkMap`

### Step 7: Validation
1. Run all existing typechecker tests: `./build/test/test`
2. Increase binop chain length in fuzz tests:
   - Edit `tests/Compiler/Fuzz/Structure.elm`
   - Change `Boolean` and `Append` from `Fuzz.constant 3` to `Fuzz.constant 4`, then `5`
3. Test with increasing fuzz count: `./build/test/test -n 100`
4. Test nested if-expressions with depth 3+
5. Confirm stack no longer overflows

**Incremental Testing Strategy:**
- After each `...Prog` function is converted, run tests immediately
- If tests fail, the most recent change is the culprit
- Keep a list of converted functions to track progress

---

## Success Criteria

1. All existing tests pass
2. Binop chain tests pass with length 3+ (currently fail at 3)
3. Fuzz tests pass at count 100+ without stack overflow
4. No changes to `System.TypeCheck.IO`
5. Stack depth remains constant regardless of AST depth

---

## Estimated Scope

| Component | New/Modified Lines |
|-----------|-------------------|
| `Compiler.Type.Constrain.Program` (new) | ~150 lines |
| `Compiler.Type.Constrain.Expression` | ~400 lines modified |
| `Compiler.Type.Constrain.Pattern` (with PatternProg DSL) | ~300 lines modified |
| `Compiler.Type.Constrain.Module` | ~50 lines modified |
| Tests (chain length updates) | ~10 lines |

**Total**: ~900-950 lines of changes