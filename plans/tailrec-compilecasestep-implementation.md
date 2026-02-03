# TailRec.compileCaseStep Implementation Plan

## Problem Summary

Tail-recursive functions with `case` expressions produce malformed MLIR because:

1. `compileCaseStep` in `TailRec.elm` (line 463-483) is a placeholder that falls back to `Expr.generateCase`
2. `Expr.generateCase` uses `generateLeafWithJumps` which calls `generateExpr` on branch bodies
3. When a branch contains `MonoTailCall`, `generateExpr` calls `generateTailCall` which emits `eco.jump` and sets `resultVar = ""`
4. `mkCaseRegionFromDecider` tries to wrap non-yield terminators with `eco.yield` using the empty `resultVar`
5. Result: `eco.yield` with 0 operands but `_operand_types` claiming 1 type

### Root Cause: Missing `MonoDestruct` Handling

**The critical bug is that `compileStep` does not handle `MonoDestruct` expressions.**

When a branch in a case expression contains pattern bindings (like `x :: xs`), the typed optimization wraps the branch body with `Destructor` nodes:

```
MonoDestruct "x" (path to head)
  MonoDestruct "xs" (path to tail)
    MonoTailCall foldl [func, func x acc, xs]
```

The current `compileStep` only handles:
- `MonoTailCall` -> `compileTailCallStep`
- `MonoCase` -> `compileCaseStep`
- `MonoIf` -> `compileIfStep`
- `MonoLet` -> `compileLetStep`
- Everything else -> `compileBaseReturnStep`

Since `MonoDestruct` is not handled, it falls through to `compileBaseReturnStep`, which:
1. Calls `Expr.generateExpr` on the whole branch expression
2. `generateExpr` processes `MonoDestruct` via `generateDestruct`
3. Eventually reaches `MonoTailCall` and calls `generateTailCall`
4. `generateTailCall` emits `eco.jump` with `resultVar = ""`
5. Back in `compileBaseReturnStep`, we get `done = true` (wrong!) and empty `resultVar`

## Solution Overview

Two-part fix:

1. **Implement `compileCaseStep`** to walk `Mono.Decider` directly, producing multi-result `eco.caseMany` operations where each alternative yields the full step tuple `(nextParams..., done, result)` via `eco.yieldMany`.

2. **Add `MonoDestruct` handling to `compileStep`** so that pattern bindings are processed as ordinary ops with variable bindings, and the body is compiled through `compileStep` (which can then see any `MonoTailCall`).

## Files to Modify

1. **`compiler/src/Compiler/Generate/MLIR/TailRec.elm`** - Main implementation
2. **`compiler/src/Compiler/Generate/MLIR/Expr.elm`** - Add defensive guard in `mkCaseRegionFromDecider`

---

## Part 1: TailRec.elm - Add `MonoDestruct` Handling

### 1.1 Add Imports

Add imports for DT types and crash utility:

```elm
import Compiler.Optimize.Typed.DecisionTree as DT
import Compiler.Generate.MLIR.Patterns as Patterns
import Utils.Crash exposing (crash)
```

Location: After line 34 (after existing imports)

### 1.2 Extend `compileStep` with `MonoDestruct` case

Modify the bottom of `compileStep` to handle `MonoDestruct`:

```elm
compileStep : Ctx.Context -> LoopSpec -> Mono.MonoExpr -> StepResult
compileStep ctx loopSpec expr =
    case expr of
        Mono.MonoTailCall _ args _ ->
            compileTailCallStep ctx loopSpec args

        Mono.MonoCase scrutinee1 scrutinee2 decider jumps resultType ->
            compileCaseStep ctx loopSpec scrutinee1 scrutinee2 decider jumps resultType

        Mono.MonoIf branches final resultType ->
            compileIfStep ctx loopSpec branches final resultType

        Mono.MonoLet def body _ ->
            compileLetStep ctx loopSpec def body

        Mono.MonoDestruct destructor body _ ->
            -- Destruct expression -> generate path + binding, then recurse on body
            compileDestructStep ctx loopSpec destructor body

        _ ->
            compileBaseReturnStep ctx loopSpec expr
```

### 1.3 Add `compileDestructStep` (new function)

This mirrors `Expr.generateDestruct` but returns `StepResult` instead of `ExprResult`:

```elm
{-| Compile a MonoDestruct step.

This mirrors Expr.generateDestruct but returns a StepResult instead of ExprResult:

  * Generate path ops to navigate the MonoPath and extract the value.
  * Bind the destructured name to the extracted SSA value in the context.
  * Recursively compile the body as a step.

This ensures that any MonoTailCall inside the body is still seen by compileStep
and treated as a "continue" step, instead of going through Expr.generateTailCall.
-}
compileDestructStep :
    Ctx.Context
    -> LoopSpec
    -> Mono.MonoDestructor
    -> Mono.MonoExpr
    -> StepResult
compileDestructStep ctx loopSpec (Mono.MonoDestructor name path _monoType) body =
    let
        -- Use the path's actual result type, as in Expr.generateDestruct.
        -- The destructor's monoType may still contain unsubstituted vars;
        -- the path carries the correctly-specialized concrete type.
        pathResultType : Mono.MonoType
        pathResultType =
            Mono.getMonoPathType path

        destructorMlirType : MlirType
        destructorMlirType =
            Types.monoTypeToAbi pathResultType

        -- Navigate the path to produce the destructured value.
        ( pathOps, pathVar, ctx1 ) =
            Patterns.generateMonoPath ctx path destructorMlirType

        -- Bind the destructured name to the extracted SSA value.
        -- Destructured bindings are plain values (no sourceArity).
        ctx2 : Ctx.Context
        ctx2 =
            Ctx.addVarMapping name pathVar destructorMlirType Nothing Nothing ctx1

        -- Recursively compile the body as a loop step.
        bodyStep : StepResult
        bodyStep =
            compileStep ctx2 loopSpec body
    in
    { ops = pathOps ++ bodyStep.ops
    , nextParams = bodyStep.nextParams
    , doneVar = bodyStep.doneVar
    , resultVar = bodyStep.resultVar
    , resultType = bodyStep.resultType
    , ctx = bodyStep.ctx
    }
```

**Why this fixes the issue:**
- The destructured bindings are created as ordinary ops and SSA vars inside the `scf.while` after-region block
- The branch body is still compiled by `compileStep`, so any `MonoTailCall` becomes a proper "continue" step (`done = false`, `nextParams = updated args`), never an `eco.jump`

### 1.4 Harden `compileBaseReturnStep` (catch missed patterns)

Make `compileBaseReturnStep` crash if it sees a terminated `ExprResult` (indicating `eco.jump` leaked through):

```elm
compileBaseReturnStep :
    Ctx.Context
    -> LoopSpec
    -> Mono.MonoExpr
    -> StepResult
compileBaseReturnStep ctx loopSpec expr =
    let
        exprResult =
            Expr.generateExpr ctx expr
    in
    if exprResult.isTerminated then
        -- This indicates a missing pattern in compileStep: a shape that
        -- eventually lowers to eco.jump/eco.return/etc is being treated
        -- as a simple value-producing base case.
        crash "TailRec.compileBaseReturnStep: encountered terminated ExprResult; extend compileStep to handle this expression shape directly."

    else
        let
            ( doneVar, ctx1 ) =
                Ctx.freshVar exprResult.ctx

            ( ctx2, doneOp ) =
                Ops.arithConstantBool ctx1 doneVar True

            nextParams =
                loopSpec.paramVars
        in
        { ops = exprResult.ops ++ [ doneOp ]
        , nextParams = nextParams
        , doneVar = doneVar
        , resultVar = exprResult.resultVar
        , resultType = exprResult.resultType
        , ctx = ctx2
        }
```

---

## Part 2: TailRec.elm - Implement `compileCaseStep`

### 2.1 Replace compileCaseStep placeholder

Replace the placeholder with a dispatcher to the new internal function:

```elm
compileCaseStep :
    Ctx.Context
    -> LoopSpec
    -> Name.Name
    -> Name.Name
    -> Mono.Decider Mono.MonoChoice
    -> List ( Int, Mono.MonoExpr )
    -> Mono.MonoType
    -> StepResult
compileCaseStep ctx loopSpec _ root decider jumps _ =
    let
        jumpLookup : Dict.Dict Int Mono.MonoExpr
        jumpLookup =
            Dict.fromList jumps
    in
    compileCaseDeciderStep ctx loopSpec root decider jumpLookup
```

### 2.2 Add compileCaseDeciderStep (new function)

```elm
{-| Compile a decision tree for a case expression as a single loop step.

This mirrors Expr.generateDeciderWithJumps, but instead of producing
an ExprResult for the case *value*, it produces a StepResult for the
loop state (nextParams..., done, result).
-}
compileCaseDeciderStep :
    Ctx.Context
    -> LoopSpec
    -> Name.Name
    -> Mono.Decider Mono.MonoChoice
    -> Dict.Dict Int Mono.MonoExpr
    -> StepResult
compileCaseDeciderStep ctx loopSpec root decider jumpLookup =
    case decider of
        Mono.Leaf choice ->
            compileCaseLeafStep ctx loopSpec choice jumpLookup

        Mono.Chain testChain success failure ->
            compileCaseChainStep ctx loopSpec root testChain success failure jumpLookup

        Mono.FanOut path edges fallback ->
            compileCaseFanOutStep ctx loopSpec root path edges fallback jumpLookup
```

### 2.3 Add compileCaseLeafStep (new function)

```elm
{-| Leaf node in the decision tree.

Inline the branch expression and treat it as the step body.
This lets compileStep see any MonoTailCall and compile it into a continue
state, instead of going through Expr.generateTailCall/eco.jump.
-}
compileCaseLeafStep :
    Ctx.Context
    -> LoopSpec
    -> Mono.MonoChoice
    -> Dict.Dict Int Mono.MonoExpr
    -> StepResult
compileCaseLeafStep ctx loopSpec choice jumpLookup =
    case choice of
        Mono.Inline branchExpr ->
            compileStep ctx loopSpec branchExpr

        Mono.Jump index ->
            case Dict.get index jumpLookup of
                Just branchExpr ->
                    compileStep ctx loopSpec branchExpr

                Nothing ->
                    crash
                        ("compileCaseLeafStep: Jump index "
                            ++ String.fromInt index
                            ++ " not found in jumpLookup"
                        )
```

### 2.4 Add compileCaseChainStep (new function)

This handles `Mono.Chain` (boolean conditions) - mirrors `Expr.generateChainGeneralWithJumps`:

```elm
{-| Chain node: sequence of tests culminating in success/failure subtrees.

We compile the chain condition to an i1, then build a 2-way eco.caseMany
on that condition where each alternative yields the full step tuple.
-}
compileCaseChainStep :
    Ctx.Context
    -> LoopSpec
    -> Name.Name
    -> List ( DT.Path, DT.Test )
    -> Mono.Decider Mono.MonoChoice
    -> Mono.Decider Mono.MonoChoice
    -> Dict.Dict Int Mono.MonoExpr
    -> StepResult
compileCaseChainStep ctx loopSpec root testChain success failure jumpLookup =
    let
        -- Compute the boolean condition (i1)
        ( condOps, condVar, condCtx ) =
            Patterns.generateChainCondition ctx root testChain

        -- Then branch
        thenStep =
            compileCaseDeciderStep condCtx loopSpec root success jumpLookup

        thenYieldOperands =
            thenStep.nextParams
                ++ [ ( thenStep.doneVar, I1 )
                   , ( thenStep.resultVar, thenStep.resultType )
                   ]

        ( thenYieldCtx, thenYieldOp ) =
            Ops.ecoYieldMany thenStep.ctx thenYieldOperands

        thenRegion =
            mkSingleBlockRegion [] thenStep.ops thenYieldOp

        -- Else branch: reuse condCtx bindings but advance nextVar
        ctxForElse =
            { condCtx | nextVar = thenYieldCtx.nextVar }

        elseStep =
            compileCaseDeciderStep ctxForElse loopSpec root failure jumpLookup

        elseYieldOperands =
            elseStep.nextParams
                ++ [ ( elseStep.doneVar, I1 )
                   , ( elseStep.resultVar, elseStep.resultType )
                   ]

        ( elseYieldCtx, elseYieldOp ) =
            Ops.ecoYieldMany elseStep.ctx elseYieldOperands

        elseRegion =
            mkSingleBlockRegion [] elseStep.ops elseYieldOp

        -- Step tuple types: (paramTypes..., i1, retTy)
        numParams =
            List.length loopSpec.paramVars

        paramTypes =
            List.map Tuple.second loopSpec.paramVars

        -- Allocate result names for the step tuple
        ( caseResultNames, ctxWithResults ) =
            allocateFreshVars elseYieldCtx (numParams + 2)

        caseResultPairs =
            zip caseResultNames (paramTypes ++ [ I1, loopSpec.retType ])

        -- eco.case on i1: tag 1 for True (then), tag 0 for False (else)
        ( ctxAfterCase, caseOp ) =
            Ops.ecoCaseMany
                ctxWithResults
                condVar
                I1
                "bool"
                [ 1, 0 ]
                [ thenRegion, elseRegion ]
                caseResultPairs

        nextParamVars =
            List.take numParams caseResultPairs

        doneResultVar =
            List.drop numParams caseResultNames
                |> List.head
                |> Maybe.withDefault "%error_no_done"

        resultResultVar =
            List.drop (numParams + 1) caseResultNames
                |> List.head
                |> Maybe.withDefault "%error_no_result"
    in
    { ops = condOps ++ [ caseOp ]
    , nextParams = nextParamVars
    , doneVar = doneResultVar
    , resultVar = resultResultVar
    , resultType = loopSpec.retType
    , ctx = ctxAfterCase
    }
```

### 2.5 Add compileCaseFanOutStep (new function)

This handles `Mono.FanOut` (constructor/Int/Char/string cases) - mirrors `Expr.generateFanOutGeneralWithJumps`:

```elm
{-| FanOut node: multi-way branching on constructor tags, ints, chars, or strings.

We generate an eco.case/eco.case_string whose result tuple is
(nextParams..., done, result). Each alternative region yields this tuple
via eco.yieldMany.
-}
compileCaseFanOutStep :
    Ctx.Context
    -> LoopSpec
    -> Name.Name
    -> DT.Path
    -> List ( DT.Test, Mono.Decider Mono.MonoChoice )
    -> Mono.Decider Mono.MonoChoice
    -> Dict.Dict Int Mono.MonoExpr
    -> StepResult
compileCaseFanOutStep ctx loopSpec root path edges fallback jumpLookup =
    let
        edgeTests =
            List.map Tuple.first edges

        caseKind =
            case edgeTests of
                firstTest :: _ ->
                    Patterns.caseKindFromTest firstTest

                [] ->
                    "ctor"

        scrutineeType =
            Patterns.scrutineeTypeFromCaseKind caseKind

        ( pathOps, scrutineeVar, ctx1 ) =
            Patterns.generateDTPath ctx root path scrutineeType

        -- Tags and (optional) string patterns
        ( tags, stringPatterns ) =
            if caseKind == "str" then
                let
                    edgeCount =
                        List.length edges

                    altCount =
                        edgeCount + 1

                    patterns =
                        edges
                            |> List.map Tuple.first
                            |> List.map extractStringPatternForStep

                    sequentialTags =
                        List.range 0 (altCount - 1)
                in
                ( sequentialTags, Just patterns )

            else
                let
                    edgeTags =
                        List.map (\( test, _ ) -> Patterns.testToTagInt test) edges

                    fallbackTag =
                        Patterns.computeFallbackTag edgeTests
                in
                ( edgeTags ++ [ fallbackTag ], Nothing )

        -- Compile edge regions
        ( edgeRegions, ctx2 ) =
            List.foldl
                (\( _, subTree ) ( accRegions, accCtx ) ->
                    let
                        subStep =
                            compileCaseDeciderStep accCtx loopSpec root subTree jumpLookup

                        yieldOperands =
                            subStep.nextParams
                                ++ [ ( subStep.doneVar, I1 )
                                   , ( subStep.resultVar, subStep.resultType )
                                   ]

                        ( yieldCtx, yieldOp ) =
                            Ops.ecoYieldMany subStep.ctx yieldOperands

                        region =
                            mkSingleBlockRegion [] subStep.ops yieldOp
                    in
                    ( accRegions ++ [ region ], yieldCtx )
                )
                ( [], ctx1 )
                edges

        -- Fallback region
        fallbackStep =
            compileCaseDeciderStep ctx2 loopSpec root fallback jumpLookup

        fallbackYieldOperands =
            fallbackStep.nextParams
                ++ [ ( fallbackStep.doneVar, I1 )
                   , ( fallbackStep.resultVar, fallbackStep.resultType )
                   ]

        ( fallbackYieldCtx, fallbackYieldOp ) =
            Ops.ecoYieldMany fallbackStep.ctx fallbackYieldOperands

        fallbackRegion =
            mkSingleBlockRegion [] fallbackStep.ops fallbackYieldOp

        allRegions =
            edgeRegions ++ [ fallbackRegion ]

        -- Step tuple result types
        numParams =
            List.length loopSpec.paramVars

        paramTypes =
            List.map Tuple.second loopSpec.paramVars

        ( caseResultNames, ctxWithResults ) =
            allocateFreshVars fallbackYieldCtx (numParams + 2)

        caseResultPairs =
            zip caseResultNames (paramTypes ++ [ I1, loopSpec.retType ])

        -- Build eco.case / eco.case_string
        ( ctx3, caseOp ) =
            case stringPatterns of
                Just patterns ->
                    Ops.ecoCaseStringMany
                        ctxWithResults
                        scrutineeVar
                        scrutineeType
                        tags
                        patterns
                        allRegions
                        caseResultPairs

                Nothing ->
                    Ops.ecoCaseMany
                        ctxWithResults
                        scrutineeVar
                        scrutineeType
                        caseKind
                        tags
                        allRegions
                        caseResultPairs

        nextParamVars =
            List.take numParams caseResultPairs

        doneResultVar =
            List.drop numParams caseResultNames
                |> List.head
                |> Maybe.withDefault "%error_no_done"

        resultResultVar =
            List.drop (numParams + 1) caseResultNames
                |> List.head
                |> Maybe.withDefault "%error_no_result"
    in
    { ops = pathOps ++ [ caseOp ]
    , nextParams = nextParamVars
    , doneVar = doneResultVar
    , resultVar = resultResultVar
    , resultType = loopSpec.retType
    , ctx = ctx3
    }
```

### 2.6 Add helper for string pattern extraction

```elm
{-| Extract string pattern from a DT.Test, crash if not a string test.
-}
extractStringPatternForStep : DT.Test -> String
extractStringPatternForStep test =
    case test of
        DT.IsStr s ->
            s

        _ ->
            crash "extractStringPatternForStep: expected DT.IsStr but got non-string test"
```

---

## Part 3: Expr.elm Defensive Guard

### 3.1 Modify mkCaseRegionFromDecider

Add a defensive check for empty `resultVar`:

```elm
mkCaseRegionFromDecider : ExprResult -> MlirType -> ( MlirRegion, Ctx.Context )
mkCaseRegionFromDecider exprRes resultTy =
    case List.reverse exprRes.ops of
        [] ->
            crash "mkCaseRegionFromDecider: empty ops - decider must produce ops"

        lastOp :: _ ->
            if isValidCaseTerminator lastOp then
                -- Already terminated with eco.yield, use as-is
                ( mkRegionFromOps exprRes.ops, exprRes.ctx )

            else if exprRes.resultVar == "" then
                -- Defensive: non-yield terminator with empty resultVar indicates
                -- a control-flow op (e.g., eco.jump) that shouldn't be wrapped
                crash
                    ("mkCaseRegionFromDecider: non-yield terminator with empty resultVar "
                        ++ "(likely eco.jump); this should not happen in yield-based case codegen"
                    )

            else
                -- Value-producing expression (e.g., nested eco.case) - wrap with eco.yield
                let
                    ( coerceOps, finalVar, ctx1 ) =
                        coerceResultToType exprRes.ctx exprRes.resultVar exprRes.resultType resultTy

                    ( ctx2, yieldOp ) =
                        Ops.ecoYield ctx1 finalVar resultTy
                in
                ( mkRegionFromOps (exprRes.ops ++ coerceOps ++ [ yieldOp ]), ctx2 )
```

---

## Part 4: Expr.elm - Document TailRec Invariant

Above `generateTailCall`, extend the doc comment:

```elm
{-| Generate MLIR code for a tail call.

This emits an `eco.jump` terminator and marks the ExprResult as
`isTerminated = True` with a meaningless `resultVar = ""`.

NOTE: This is only for joinpoint-based tail-call lowering. Tail-recursive
functions that are compiled via Compiler.Generate.MLIR.TailRec must never
reach `generateTailCall`; they compile tail calls as "continue" steps in
`TailRec.compileStep` instead of emitting `eco.jump`.
-}
generateTailCall : Ctx.Context -> Name.Name -> List ( Name.Name, Mono.MonoExpr ) -> ExprResult
```

---

## Testing

After implementation, run:

```bash
# Frontend tests
cd compiler && npx elm-test-rs --fuzz 1

# Quick single test
TEST_FILTER=elm-core/ListReverseTest cmake --build build --target check

# Full elm-core tests
TEST_FILTER=elm-core cmake --build build --target check
```

Focus on test cases with tail-recursive functions that use `case` expressions:
- `List.foldl`, `List.foldr`
- `List.map`, `List.filter`
- `List.reverse`
- Any functions using pattern matching in tail-recursive loops

---

## Expected Outcome

After implementation:

1. **No malformed `eco.yield` ops** - There should no longer be:
   ```mlir
   "eco.yield"() {_operand_types = [!eco.value]} : (!eco.value) -> ()
   ```

2. **Correct loop state updates in case branches** - In the non-empty list branch of a `foldl`-like function, the MLIR should show:
   - Projections for `x` and `xs` using `eco.project.list_head`/`eco.project.list_tail`
   - Evaluation of the new accumulator
   - A tail call step that sets `done = false` and carries updated parameters

3. **Early failure if you miss another wrapper** - If some other expression form that can contain a `MonoTailCall` is not handled in `compileStep`, you'll get a clear crash instead of malformed MLIR.

---

## Summary of Changes

| File | Change Type | Description |
|------|-------------|-------------|
| `TailRec.elm` | Add import | `import Compiler.Optimize.Typed.DecisionTree as DT` |
| `TailRec.elm` | Add import | `import Utils.Crash exposing (crash)` |
| `TailRec.elm` | Modify | `compileStep` - add `MonoDestruct` case |
| `TailRec.elm` | Add | `compileDestructStep` - handle destructors structurally |
| `TailRec.elm` | Modify | `compileBaseReturnStep` - crash on terminated ExprResult |
| `TailRec.elm` | Replace | `compileCaseStep` - dispatch to new walker |
| `TailRec.elm` | Add | `compileCaseDeciderStep` - decision tree dispatcher |
| `TailRec.elm` | Add | `compileCaseLeafStep` - leaf node handling |
| `TailRec.elm` | Add | `compileCaseChainStep` - chain/boolean conditions |
| `TailRec.elm` | Add | `compileCaseFanOutStep` - multi-way branching |
| `TailRec.elm` | Add | `extractStringPatternForStep` - helper for string cases |
| `Expr.elm` | Modify | `mkCaseRegionFromDecider` - add defensive guard |
| `Expr.elm` | Modify | `generateTailCall` - add doc comment about TailRec invariant |

---

## Part 5: Fix Type Mismatch in `compileBaseReturnStep`

### Problem: Type Mismatch in eco.case Yields

After implementing Parts 1-4, tests fail with:
```
'eco.case' op alternative 0 eco.yield operand 4 has type 'i64' but eco.case result 4 has type '!eco.value'
```

**Root cause:** `compileBaseReturnStep` forwards `exprResult.resultType` directly into `StepResult.resultType`. When a base case returns a primitive accumulator (`i64`) while `loopSpec.retType` is `!eco.value` (or vice versa), the types diverge.

### Invariant

> For all `StepResult` values produced by `compileStep`, we must have  
> `stepResult.resultType == loopSpec.retType`.

This is already satisfied by:
- Tail call step: `resultType = loopSpec.retType` with dummy result from `Expr.createDummyValue`
- Case step (chain/fanout) and if step: both set `resultType = loopSpec.retType` explicitly

The outlier is `compileBaseReturnStep`.

### Fix: Coerce to `loopSpec.retType`

In `compileBaseReturnStep`, after `Expr.generateExpr`, coerce the expression result to `loopSpec.retType` using `Expr.coerceResultToType`.

```elm
compileBaseReturnStep ctx loopSpec expr =
    let
        exprResult =
            Expr.generateExpr ctx expr
    in
    if exprResult.isTerminated then
        crash "..."
    else
        let
            -- Coerce the expression result to the loop's result MLIR type.
            ( coerceOps, finalVar, ctx1 ) =
                Expr.coerceResultToType
                    exprResult.ctx
                    exprResult.resultVar
                    exprResult.resultType
                    loopSpec.retType

            ( doneVar, ctx2 ) =
                Ctx.freshVar ctx1

            ( ctx3, doneOp ) =
                Ops.arithConstantBool ctx2 doneVar True

            nextParams =
                loopSpec.paramVars
        in
        { ops = exprResult.ops ++ coerceOps ++ [ doneOp ]
        , nextParams = nextParams
        , doneVar = doneVar
        , resultVar = finalVar
        , resultType = loopSpec.retType
        , ctx = ctx3
        }
```

### Update StepResult Documentation

Add invariant documentation to the `StepResult` type alias:

```elm
{-| Result of compiling a single step of the loop body.

Invariant: resultType must always equal loopSpec.retType for the enclosing
compileStep/LoopSpec. All step forms (tail calls, base returns, cases, ifs)
are responsible for producing a resultVar of this type.
-}
type alias StepResult = ...
```
