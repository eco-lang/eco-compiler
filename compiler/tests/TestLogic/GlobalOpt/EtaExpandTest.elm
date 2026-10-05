module TestLogic.GlobalOpt.EtaExpandTest exposing (suite)

{-| Tests for `Compiler.GlobalOpt.PreMono.EtaExpand`, the pass that gives a
definition, or a lambda passed as an argument, the extra parameters its type
declares. Without them, the pass could stop expanding where it should, or start
expanding where it must not, unnoticed.

The _declared arity_ of a definition is the number of parameters its type has
once type aliases are expanded; its _syntactic arity_ is the number its body
writes. The pass acts where the declared arity is the larger. A definition
annotated `St Int`, where `St a` is an alias for `Int -> a`, looks like a value
but declares one parameter, and that is the case most fixtures are built
around.

The pass has two rules. The _definition rule_ expands a definition to its
declared arity, and the _continuation rule_ expands a lambda passed as an
argument to the arity that the callee's parameter type declares. The _cheapness
gate_ refuses an expansion unless the work done before the new parameters is of
a form it counts as cheap, because expanding moves that work from once to once
per call.

Each fixture is a module built with `makeModuleWithTypedDefsUnionsAliases`. It
declares `type alias St a = Int -> a` and five base definitions, all written
with as many parameters as their types declare (the body of `andThen` applies
`f` one argument at a time, as two nested calls):

    andThen : (a -> St b) -> St a -> St b
    andThen f ma s0 =
        f (ma s0) s0

    pure : a -> St a
    pure x s =
        x

    tick : St Int
    tick s =
        s

    plus : Int -> Int -> Int
    plus a b =
        a

    expensive : Int -> Int
    expensive n =
        plus (plus n n) n

It adds the definitions under test and a `testValue : Int`, which
`TestPipeline` requires and which calls or references them. A fixture goes
through `TestPipeline.runToAssigned`, and `EtaExpand.run` is called on the graph
that returns, with `etaExpand` on unless a test says otherwise. That graph also
holds the harness's two kernel-alias nodes, `List.cons` and `List.map2`, each a
definition whose whole body is a kernel reference. The counters the tests read
are fields of `EtaExpand.Metrics`.

What the tests establish:

  - Run on `prog = andThen (\a -> pure a) tick`, with `prog : St Int`,
    `bodiesSeen` is above zero.
  - On the same `prog`, after the pass its body is a one-parameter lambda, the
    first call in that body has three arguments, the only lambda below it (the
    continuation) has two parameters, `defs` and `conts` are both 1, and
    `merged` is above zero.
  - For `d = tick`, with `d : St Int`, the body of `d` becomes a one-parameter
    lambda whose first call has one argument.
  - For `d n = tick`, with `d : Int -> St Int`, the body of `d` becomes a lambda
    of two parameters.
  - For `prog s0 = andThen (\a s1 -> a) tick s0`, `conts` is 0 and the one
    lambda below `prog`'s own has two parameters.
  - For a recursive `sequence`, which becomes a function definition in a
    `Cycle` node, `cycleDefs` is above zero, its `case` has a `jumps` entry,
    and in the Cycle's function definitions each `andThen` call has three
    arguments and each `pure` and `sequence` call has two, so every branch,
    the shared one included, received the new argument.
  - For a self-tail-recursive `loop : Int -> St Int` written with one
    parameter, `tailDef` is above zero.
  - For `d = let big = expensive 1 in pure big`, and separately for
    `d = pure (expensive 1)`, `notCheap` is above zero and the body of `d` is
    not a lambda.
  - For `d = 5`, with `d : Int`, `noSpine` is exactly one more than for the
    same fixture without `d` (`testValue : Int` is itself declined as
    `noSpine`), and the body of `d` is not a lambda.
  - On `chainModule`'s graph, `kernelAlias` is exactly 2, the harness's two
    kernel-alias nodes, and both still have a bare `VarKernel` body after the
    pass.
  - For `mkU8 = U8` and `mkU32 = U32`, two constructors of a custom type,
    `ctorAlias` is at least 2 and neither body becomes a lambda.
  - With `etaExpand` off, on the first test's `prog`, the body of `prog` has the
    same parameter count before and after, and `defs` and `conts` are both
    still 1.

Among what is not tested: a kernel alias written in the fixture itself; that a
declined tail-recursive definition's body is
unchanged; the `etaOnly` allow-list; recursive values in a `Cycle`; and whether
the expanded graph can still be monomorphized.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( AliasDef
        , TypedDef
        , binopsExpr
        , callExpr
        , caseExpr
        , ctorExpr
        , define
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pAnything
        , pList
        , pVar
        , qualVarExpr
        , tLambda
        , tType
        , tVar
        , varExpr
        )
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name exposing (Name)
import Compiler.Eco.Config as Config
import Compiler.GlobalOpt.PreMono.EtaExpand as EtaExpand
import Data.Map
import Dict as CoreDict
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The whole suite: the counter that shows the pass ran, the definition and
continuation rules, `Cycle` members, the cheapness gate, the refusals by shape,
and the flag-off behaviour.
-}
suite : Test
suite =
    Test.describe "EtaExpand (pre-mono)"
        [ denominatorSuite
        , definitionSuite
        , continuationSuite
        , cycleSuite
        , gateSuite
        , scopeSuite
        , inertSuite
        ]



-- ============================================================================
-- THE DENOMINATOR
-- ============================================================================


{-| The test that `bodiesSeen` is above zero for `chainModule`.
-}
denominatorSuite : Test
denominatorSuite =
    Test.describe "Denominator"
        [ Test.test "the pass examines top-level bodies at all" <|
            \_ ->
                -- `defs = 0` cannot tell a pass that refused every body from
                -- one that matched no node shape at all; this counter can.
                withMetrics chainModule
                    (\m ->
                        if m.bodiesSeen > 0 then
                            Expect.pass

                        else
                            Expect.fail "EtaExpand matched no top-level body"
                    )
        ]



-- ============================================================================
-- THE DEFINITION RULE
-- ============================================================================


{-| The tests of the definition rule. For each of `chainModule`,
`bareGlobalModule` and `partialArityModule` they check the parameter count of
the expanded body. For `chainModule` and `bareGlobalModule` they also check the
argument count of the body's first call, and for `chainModule` the
continuation's parameters and the `defs`, `conts` and `merged` counters.
-}
definitionSuite : Test
definitionSuite =
    Test.describe "Definition rule"
        [ Test.test "F1: a 2-of-3 andThen chain gains the state parameter" <|
            \_ ->
                withGraph chainModule
                    (\g -> Expect.equal (Just 1) (nodeParamCount g "prog"))
        , Test.test "F1: the andThen call reaches three arguments" <|
            \_ ->
                withGraph chainModule
                    (\g -> Expect.equal (Just 3) (List.head (callArgCounts g "prog")))
        , Test.test "F1: the continuation gains its own state parameter" <|
            \_ ->
                withGraph chainModule
                    (\g -> Expect.equal [ 2 ] (lambdaParamCounts g "prog"))
        , Test.test "F1: one definition and one continuation are counted" <|
            \_ ->
                withMetrics chainModule
                    (\m -> Expect.equal ( 1, 1 ) ( m.defs, m.conts ))
        , Test.test "F1: the merge is counted" <|
            \_ ->
                withMetrics chainModule
                    (\m ->
                        if m.merged > 0 then
                            Expect.pass

                        else
                            Expect.fail "expected the new argument to MERGE into the andThen call"
                    )
        , Test.test "F2: a bare global of alias-arrow type becomes a lambda" <|
            \_ ->
                withGraph bareGlobalModule
                    (\g -> Expect.equal (Just 1) (nodeParamCount g "d"))
        , Test.test "F2: the bare global's reference becomes a saturated call" <|
            \_ ->
                withGraph bareGlobalModule
                    (\g -> Expect.equal (Just 1) (List.head (callArgCounts g "d")))
        , Test.test "F3: partial syntactic arity is topped up, not replaced" <|
            \_ ->
                -- `d : Int -> St Int` written with one parameter declares two.
                withGraph partialArityModule
                    (\g -> Expect.equal (Just 2) (nodeParamCount g "d"))
        ]



-- ============================================================================
-- THE CONTINUATION RULE
-- ============================================================================


{-| The tests that a continuation already written with both of its declared
parameters, in `saturatedContModule`, is not counted in `conts` and still has
two parameters.
-}
continuationSuite : Test
continuationSuite =
    Test.describe "Continuation rule"
        [ Test.test "F4: an already-saturated continuation is left alone" <|
            \_ ->
                withMetrics saturatedContModule (\m -> Expect.equal 0 m.conts)
        , Test.test "F4: an already-saturated continuation keeps two parameters" <|
            \_ ->
                withGraph saturatedContModule
                    (\g -> Expect.equal [ 2 ] (lambdaParamCounts g "prog"))
        ]



-- ============================================================================
-- CYCLE MEMBERS
-- ============================================================================


{-| The tests of the recursive definitions. For `sequenceModule`, `cycleDefs`
is above zero, the `Cycle`'s `case` has a `jumps` entry, and in its function
definitions every `andThen` call has three arguments and every `pure` and
`sequence` call two. For `tailDefModule`,
`tailDef` is above zero.
-}
cycleSuite : Test
cycleSuite =
    Test.describe "Cycle members"
        [ Test.test "F5: a recursive sequence-shaped definition expands" <|
            \_ ->
                withMetrics sequenceModule
                    (\m ->
                        if m.cycleDefs > 0 then
                            Expect.pass

                        else
                            Expect.fail "expected the Cycle Def to be η-expanded"
                    )
        , Test.test "F5: the fixture's case shares a branch through jumps" <|
            \_ ->
                -- Without a `jumps` entry the next test would check only the
                -- decider's `Inline` leaves.
                withGraph sequenceModule
                    (\g ->
                        if cycleJumpCount g > 0 then
                            Expect.pass

                        else
                            Expect.fail "expected the Cycle's case to have a jumps entry"
                    )
        , Test.test "F5: EVERY case branch is saturated, jumps included (R8)" <|
            \_ ->
                -- A new argument pushed into the decider's `Inline` leaves but
                -- not into `jumps` would leave a shared branch under-applied.
                -- Saturated, `andThen` takes three arguments, and `pure` and
                -- `sequence` take two; unexpanded, the branches give them two,
                -- one and one.
                withGraph sequenceModule
                    (\g ->
                        Expect.equal
                            { andThen = [ 3, 3 ], pure = [ 2, 2 ], sequence = [ 2 ] }
                            { andThen = cycleCallArgCounts "andThen" g
                            , pure = cycleCallArgCounts "pure" g
                            , sequence = cycleCallArgCounts "sequence" g
                            }
                    )
        , Test.test "F6: a TailDef with a deficit is declined" <|
            \_ ->
                withMetrics tailDefModule
                    (\m ->
                        if m.tailDef > 0 then
                            Expect.pass

                        else
                            Expect.fail "expected the TailDef to be counted as declined"
                    )
        ]



-- ============================================================================
-- THE CHEAPNESS GATE
-- ============================================================================


{-| The tests that the cheapness gate refuses `expensiveLetModule` and
`notCheapArgModule`. For each, `notCheap` is above zero and the body of `d` is
not a lambda.
-}
gateSuite : Test
gateSuite =
    Test.describe "Cheapness gate"
        [ Test.test "F7: an expensive let-bound value is declined" <|
            \_ ->
                withMetrics expensiveLetModule
                    (\m ->
                        if m.notCheap > 0 then
                            Expect.pass

                        else
                            Expect.fail "expected the expensive `let` body to be refused"
                    )
        , Test.test "F7: the expensive definition is left as a bare value" <|
            \_ ->
                withGraph expensiveLetModule
                    (\g -> Expect.equal Nothing (nodeParamCount g "d"))
        , Test.test "F8: an over-threshold saturated call in argument position is declined" <|
            \_ ->
                withMetrics notCheapArgModule
                    (\m ->
                        if m.notCheap > 0 then
                            Expect.pass

                        else
                            Expect.fail "expected the over-threshold argument to be refused"
                    )
        , Test.test "F8: that definition is left as a bare value" <|
            \_ ->
                withGraph notCheapArgModule
                    (\g -> Expect.equal Nothing (nodeParamCount g "d"))
        ]



-- ============================================================================
-- SCOPE
-- ============================================================================


{-| The tests of the definitions refused by their shape. For `noSpineModule`,
`noSpine` is one more than for `noSpineControlModule`, which lacks only `d`,
and the body of `d` is not a lambda. For `chainModule`, `kernelAlias` is
exactly 2, the harness's two kernel-alias nodes, and both nodes still have a
bare `VarKernel` body after the pass. For `ctorAliasModule`, `ctorAlias` is at least 2, and neither the body of
`mkU8` nor that of `mkU32` is a lambda.
-}
scopeSuite : Test
scopeSuite =
    Test.describe "Scope"
        [ Test.test "F9: a type with no arrow spine is declined as noSpine" <|
            \_ ->
                -- Every fixture's `testValue : Int` is itself declined as
                -- noSpine, so the count is compared with that of the same
                -- fixture without `d`.
                withMetrics noSpineControlModule
                    (\control ->
                        withMetrics noSpineModule
                            (\m -> Expect.equal (control.noSpine + 1) m.noSpine)
                    )
        , Test.test "the harness's kernel-alias nodes are refused (LSS_016)" <|
            \_ ->
                -- The harness adds `List.cons` and `List.map2` as kernel
                -- aliases to every graph; the fixture has none of its own.
                -- `LssInfer.kernelAliasOf` recognises one only by a node whose
                -- whole body is a `VarKernel`, so an expanded alias would no
                -- longer be recognised.
                withMetrics chainModule (\m -> Expect.equal 2 m.kernelAlias)
        , Test.test "the harness's kernel-alias nodes are never rewritten" <|
            \_ ->
                case Pipeline.runToAssigned chainModule of
                    Err msg ->
                        Expect.fail msg

                    Ok assigned ->
                        let
                            ( after, _, _ ) =
                                EtaExpand.run etaConfig assigned.mvarState assigned.graph
                        in
                        Expect.equal
                            ( 2, kernelAliasNodeCount assigned.graph )
                            ( kernelAliasNodeCount assigned.graph, kernelAliasNodeCount after )
        , Test.test "F9: a type with no arrow spine is never rewritten" <|
            \_ ->
                withGraph noSpineModule
                    (\g -> Expect.equal Nothing (nodeParamCount g "d"))
        , Test.test "a constructor alias is refused (ctorAlias)" <|
            \_ ->
                -- `mkU8 = U8` has the shape of elm/bytes' `unsignedInt8 = U8`.
                -- Expanding a bare constructor gains no arity, and the pass
                -- leaves it alone so that passes recognising a call by the
                -- global's name, such as bytes fusion, still see it.
                withMetrics ctorAliasModule
                    (\m ->
                        if m.ctorAlias >= 2 then
                            Expect.pass

                        else
                            Expect.fail ("expected both constructor aliases to be refused, ctorAlias=" ++ String.fromInt m.ctorAlias)
                    )
        , Test.test "a constructor alias is never rewritten" <|
            \_ ->
                withGraph ctorAliasModule
                    (\g -> Expect.equal ( Nothing, Nothing ) ( nodeParamCount g "mkU8", nodeParamCount g "mkU32" ))
        ]



-- ============================================================================
-- FLAG OFF
-- ============================================================================


{-| The tests of `chainModule` with `etaExpand` off: `prog`'s parameter count
does not change, and the counters still report one definition and one
continuation.
-}
inertSuite : Test
inertSuite =
    Test.describe "Flag off"
        [ Test.test "with etaExpand off the graph comes back untouched" <|
            \_ ->
                case Pipeline.runToAssigned chainModule of
                    Err msg ->
                        Expect.fail msg

                    Ok assigned ->
                        let
                            ( after, _, _ ) =
                                EtaExpand.run offInline assigned.mvarState assigned.graph
                        in
                        Expect.equal
                            (nodeParamCount assigned.graph "prog")
                            (nodeParamCount after "prog")
        , Test.test "with etaExpand off the census still classifies" <|
            \_ ->
                -- The rules still run and count; only their result is
                -- discarded.
                case Pipeline.runToAssigned chainModule of
                    Err msg ->
                        Expect.fail msg

                    Ok assigned ->
                        let
                            ( _, _, m ) =
                                EtaExpand.run offInline assigned.mvarState assigned.graph
                        in
                        Expect.equal ( 1, 1 ) ( m.defs, m.conts )
        ]



-- ============================================================================
-- HARNESS
-- ============================================================================


{-| The default inline configuration with `etaExpand` set on, so that the
tests do not depend on the default.
-}
etaConfig : Config.InlineConfig
etaConfig =
    { defaultInline | etaExpand = True }


{-| The project's default inline configuration, `Config.default.inline`.
-}
defaultInline : Config.InlineConfig
defaultInline =
    Config.default.inline


{-| The default inline configuration with `etaExpand` set off. The default
has it on.
-}
offInline : Config.InlineConfig
offInline =
    { defaultInline | etaExpand = False }


{-| Runs `srcModule` through `TestPipeline.runToAssigned` and `EtaExpand.run`
with `etaConfig`, and applies `check` to the metrics. If `runToAssigned`
returns an error, the test fails with its message.
-}
withMetrics : Src.Module -> (EtaExpand.Metrics -> Expect.Expectation) -> Expect.Expectation
withMetrics srcModule check =
    case Pipeline.runToAssigned srcModule of
        Err msg ->
            Expect.fail msg

        Ok assigned ->
            let
                ( _, _, m ) =
                    EtaExpand.run etaConfig assigned.mvarState assigned.graph
            in
            check m


{-| Runs `srcModule` through `TestPipeline.runToAssigned` and `EtaExpand.run`
with `etaConfig`, and applies `check` to the rewritten graph. If
`runToAssigned` returns an error, the test fails with its message.
-}
withGraph : Src.Module -> (TOpt.GlobalGraph TypeIds.MVarId -> Expect.Expectation) -> Expect.Expectation
withGraph srcModule check =
    case Pipeline.runToAssigned srcModule of
        Err msg ->
            Expect.fail msg

        Ok assigned ->
            let
                ( after, _, _ ) =
                    EtaExpand.run etaConfig assigned.mvarState assigned.graph
            in
            check after



-- ====== STRUCTURAL READERS ======


{-| Returns the body of the `Define` or `TrackedDefine` node whose value name is
`name`, in any module. `Nothing` when there is none, which includes a definition
that is a member of a `Cycle`.
-}
nodeBody : TOpt.GlobalGraph TypeIds.MVarId -> Name -> Maybe (TOpt.Expr TypeIds.MVarId)
nodeBody (TOpt.GlobalGraph nodes _ _ _ _) name =
    Data.Map.foldl
        (\(TOpt.Global _ n) node acc ->
            if n == name then
                case node of
                    TOpt.Define e _ _ ->
                        Just e

                    TOpt.TrackedDefine _ e _ _ ->
                        Just e

                    _ ->
                        acc

            else
                acc
        )
        Nothing
        nodes


{-| Returns the number of parameters of the lambda that is the body of the
definition named `name`, as `nodeBody` finds it. `Nothing` when the body is not
a lambda, which for a value definition means it was not expanded, or when no
such definition is found.
-}
nodeParamCount : TOpt.GlobalGraph TypeIds.MVarId -> Name -> Maybe Int
nodeParamCount graph name =
    case nodeBody graph name of
        Just (TOpt.Function _ ps _ _) ->
            Just (List.length ps)

        Just (TOpt.TrackedFunction _ ps _ _) ->
            Just (List.length ps)

        _ ->
            Nothing


{-| Returns the argument count of every call in the body of the definition
named `name`, in pre-order, so an enclosing call comes before the calls inside
it. Empty when no such definition is found.
-}
callArgCounts : TOpt.GlobalGraph TypeIds.MVarId -> Name -> List Int
callArgCounts graph name =
    case nodeBody graph name of
        Just body ->
            collectCalls body

        Nothing ->
            []


{-| Returns the argument count of every call in `expr`, `expr` itself
included, in pre-order. It descends only where `children` does.
-}
collectCalls : TOpt.Expr TypeIds.MVarId -> List Int
collectCalls expr =
    (case expr of
        TOpt.Call _ _ args _ ->
            [ List.length args ]

        _ ->
            []
    )
        ++ List.concatMap collectCalls (children expr)


{-| Returns the parameter count of every lambda in the body of the definition
named `name`, excluding the body itself.
-}
lambdaParamCounts : TOpt.GlobalGraph TypeIds.MVarId -> Name -> List Int
lambdaParamCounts graph name =
    case nodeBody graph name of
        Just body ->
            List.concatMap collectLambdas (children body)

        Nothing ->
            []


{-| Returns the parameter count of every lambda in `expr`, `expr` itself
included, in pre-order. It descends only where `children` does.
-}
collectLambdas : TOpt.Expr TypeIds.MVarId -> List Int
collectLambdas expr =
    (case expr of
        TOpt.Function _ ps _ _ ->
            [ List.length ps ]

        TOpt.TrackedFunction _ ps _ _ ->
            [ List.length ps ]

        _ ->
            []
    )
        ++ List.concatMap collectLambdas (children expr)


{-| Returns the argument count of every call to the global named `name` in the
function definitions of every `Cycle` node in the graph, in pre-order. A
`Cycle`'s recursive values are not read.
-}
cycleCallArgCounts : Name -> TOpt.GlobalGraph TypeIds.MVarId -> List Int
cycleCallArgCounts name graph =
    List.concatMap (collectCallsTo name) (cycleFuncBodies graph)


{-| Returns the number of `jumps` entries of every `case` in the function
definitions of every `Cycle` node in the graph.
-}
cycleJumpCount : TOpt.GlobalGraph TypeIds.MVarId -> Int
cycleJumpCount graph =
    List.sum (List.map countJumps (cycleFuncBodies graph))


{-| Returns the bodies of the function definitions of every `Cycle` node in the
graph.
-}
cycleFuncBodies : TOpt.GlobalGraph TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId)
cycleFuncBodies (TOpt.GlobalGraph nodes _ _ _ _) =
    Data.Map.foldl
        (\_ node acc ->
            case node of
                TOpt.Cycle _ _ funcDefs _ ->
                    acc
                        ++ List.map
                            (\def ->
                                case def of
                                    TOpt.Def _ _ body _ ->
                                        body

                                    TOpt.TailDef _ _ _ body _ _ ->
                                        body
                            )
                            funcDefs

                _ ->
                    acc
        )
        []
        nodes


{-| Returns the argument count of every call in `expr` whose function is the
global named `name`, `expr` itself included, in pre-order.
-}
collectCallsTo : Name -> TOpt.Expr TypeIds.MVarId -> List Int
collectCallsTo name expr =
    (case expr of
        TOpt.Call _ (TOpt.VarGlobal _ (TOpt.Global _ n) _) args _ ->
            if n == name then
                [ List.length args ]

            else
                []

        _ ->
            []
    )
        ++ List.concatMap (collectCallsTo name) (children expr)


{-| Returns the number of `jumps` entries of every `case` in `expr`, `expr`
itself included.
-}
countJumps : TOpt.Expr TypeIds.MVarId -> Int
countJumps expr =
    (case expr of
        TOpt.Case _ _ _ jumps _ ->
            List.length jumps

        _ ->
            0
    )
        + List.sum (List.map countJumps (children expr))


{-| Returns the number of `Define` nodes in the graph whose whole body is a
`VarKernel`, the shape `LssInfer.kernelAliasOf` recognises as a kernel alias.
-}
kernelAliasNodeCount : TOpt.GlobalGraph TypeIds.MVarId -> Int
kernelAliasNodeCount (TOpt.GlobalGraph nodes _ _ _ _) =
    Data.Map.foldl
        (\_ node acc ->
            case node of
                TOpt.Define (TOpt.VarKernel _ _ _ _ _) _ _ ->
                    acc + 1

                _ ->
                    acc
        )
        0
        nodes


{-| Returns the immediate sub-expressions of `expr`. For a `let`, these are the
bound expression and the body. For a `case`, they are the expressions at the
decision tree's inline leaves followed by the shared branches in its `jumps`
list.
-}
children : TOpt.Expr TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId)
children expr =
    case expr of
        TOpt.List _ items _ ->
            items

        TOpt.Function _ _ body _ ->
            [ body ]

        TOpt.TrackedFunction _ _ body _ ->
            [ body ]

        TOpt.Call _ f args _ ->
            f :: args

        TOpt.TailCall _ args _ ->
            List.map Tuple.second args

        TOpt.If branches final _ ->
            List.concatMap (\( c, t ) -> [ c, t ]) branches ++ [ final ]

        TOpt.Let def body _ ->
            (case def of
                TOpt.Def _ _ bound _ ->
                    [ bound ]

                TOpt.TailDef _ _ _ b _ _ ->
                    [ b ]
            )
                ++ [ body ]

        TOpt.Destruct _ body _ ->
            [ body ]

        TOpt.Case _ _ decider jumps _ ->
            deciderChildren decider ++ List.map Tuple.second jumps

        TOpt.Access inner _ _ _ ->
            [ inner ]

        TOpt.Update _ record fields _ ->
            record :: Data.Map.values fields

        TOpt.Record fields _ ->
            CoreDict.values fields

        TOpt.TrackedRecord _ fields _ ->
            Data.Map.values fields

        TOpt.Tuple _ a b rest _ ->
            a :: b :: rest

        _ ->
            []


{-| Returns the expressions at the inline leaves of a decision tree, in order.
A leaf that jumps to a shared branch gives none; `children` reads those
branches from the `jumps` list.
-}
deciderChildren : TOpt.Decider (TOpt.Choice TypeIds.MVarId) -> List (TOpt.Expr TypeIds.MVarId)
deciderChildren decider =
    case decider of
        TOpt.Leaf (TOpt.Inline e) ->
            [ e ]

        TOpt.Leaf (TOpt.Jump _) ->
            []

        TOpt.Chain _ ok ko ->
            deciderChildren ok ++ deciderChildren ko

        TOpt.FanOut _ branches fallback ->
            List.concatMap (\( _, d ) -> deciderChildren d) branches
                ++ deciderChildren fallback



-- ============================================================================
-- FIXTURES
-- ============================================================================


{-| The alias every fixture declares, `type alias St a = Int -> a`: a state
monad whose state is an `Int` and whose action returns only its result.

The state is not returned alongside the result, so no fixture needs
`Tuple.first` or `Tuple.second`, and `Tuple` is not among the modules
`makeModuleWithTypedDefsUnionsAliases` imports. No fixture instantiates `a` with
a function type, so every declared arity is the same as it would be with the
state returned alongside the result.

-}
stAlias : AliasDef
stAlias =
    { name = "St"
    , args = [ "a" ]
    , tipe = tLambda (tType "Int" []) (tVar "a")
    }


{-| Builds the source type `St inner`.
-}
tSt : Src.Type -> Src.Type
tSt inner =
    tType "St" [ inner ]


{-| The source type `Int`.
-}
tInt : Src.Type
tInt =
    tType "Int" []


{-| The base definition `andThen : (a -> St b) -> St a -> St b`, written with
all three parameters its type declares. Its body applies `f` one argument at
a time, as two nested calls:

    andThen f ma s0 =
        f (ma s0) s0

-}
andThenDef : TypedDef
andThenDef =
    { name = "andThen"
    , args = [ pVar "f", pVar "ma", pVar "s0" ]
    , tipe =
        tLambda (tLambda (tVar "a") (tSt (tVar "b")))
            (tLambda (tSt (tVar "a")) (tSt (tVar "b")))
    , body =
        callExpr (callExpr (varExpr "f") [ callExpr (varExpr "ma") [ varExpr "s0" ] ])
            [ varExpr "s0" ]
    }


{-| The base definition `pure : a -> St a`, written as `pure x s = x`, with
both parameters its type declares.
-}
pureDef : TypedDef
pureDef =
    { name = "pure"
    , args = [ pVar "x", pVar "s" ]
    , tipe = tLambda (tVar "a") (tSt (tVar "a"))
    , body = varExpr "x"
    }


{-| The base definition `tick : St Int`, written as `tick s = s`, with the
one parameter its type declares. Fixtures use it as the action passed to
`andThen` and as the body of a definition to be expanded.
-}
tickDef : TypedDef
tickDef =
    { name = "tick"
    , args = [ pVar "s" ]
    , tipe = tSt tInt
    , body = varExpr "s"
    }


{-| The base definition `plus : Int -> Int -> Int`, written as `plus a b = a`.
It exists to give `expensive` a body of calls.
-}
plusDef : TypedDef
plusDef =
    { name = "plus"
    , args = [ pVar "a", pVar "b" ]
    , tipe = tLambda tInt (tLambda tInt tInt)
    , body = varExpr "a"
    }


{-| The base definition `expensive : Int -> Int`, written as
`expensive n = plus (plus n n) n`. Its body costs 15 under `EtaExpand`'s cost
measure, above the default `etaThreshold` of 10, so the cheapness gate refuses
a call that passes it its one argument.
-}
expensiveDef : TypedDef
expensiveDef =
    { name = "expensive"
    , args = [ pVar "n" ]
    , tipe = tLambda tInt tInt
    , body =
        callExpr (varExpr "plus")
            [ callExpr (varExpr "plus") [ varExpr "n", varExpr "n" ], varExpr "n" ]
    }


{-| The base definitions every fixture includes: `andThen`, `pure`, `tick`,
`plus` and `expensive`.
-}
base : List TypedDef
base =
    [ andThenDef, pureDef, tickDef, plusDef, expensiveDef ]


{-| Builds a fixture module named `Test` holding the base definitions, then
`defs`, and the `St` alias, with no custom types.
-}
module_ : List TypedDef -> Src.Module
module_ defs =
    makeModuleWithTypedDefsUnionsAliases "Test" (base ++ defs) [] [ stAlias ]


{-| A fixture with two constructor aliases, definitions whose whole body is a
constructor of `type Enc = U8 Int | U32 Int Int`:

    mkU8 : Int -> Enc
    mkU8 =
        U8

    mkU32 : Int -> Int -> Enc
    mkU32 =
        U32

`testValue` passes `mkU8 3` and `mkU32 1 2` to `use : Enc -> Int`.

-}
ctorAliasModule : Src.Module
ctorAliasModule =
    makeModuleWithTypedDefsUnionsAliases "Test"
        (base
            ++ [ { name = "mkU8"
                 , args = []
                 , tipe = tLambda tInt (tType "Enc" [])
                 , body = ctorExpr "U8"
                 }
               , { name = "mkU32"
                 , args = []
                 , tipe = tLambda tInt (tLambda tInt (tType "Enc" []))
                 , body = ctorExpr "U32"
                 }
               , { name = "use"
                 , args = [ pVar "e" ]
                 , tipe = tLambda (tType "Enc" []) tInt
                 , body = intExpr 1
                 }
               , testValueDef
                    (binopsExpr [ ( callExpr (varExpr "use") [ callExpr (varExpr "mkU8") [ intExpr 3 ] ], "+" ) ]
                        (callExpr (varExpr "use") [ callExpr (varExpr "mkU32") [ intExpr 1, intExpr 2 ] ])
                    )
               ]
        )
        [ { name = "Enc"
          , args = []
          , ctors =
                [ { name = "U8", args = [ tInt ] }
                , { name = "U32", args = [ tInt, tInt ] }
                ]
          }
        ]
        [ stAlias ]


{-| Builds the `testValue : Int` definition, with no parameters, with `body` as
its body. `TestPipeline` requires it of a program run to typed optimization or
beyond, as `runToAssigned` does.
-}
testValueDef : Src.Expr -> TypedDef
testValueDef body =
    { name = "testValue", args = [], tipe = tInt, body = body }


{-| A fixture whose definition and continuation both fall short of their
declared arity:

    prog : St Int
    prog =
        andThen (\a -> pure a) tick

`prog` writes no parameter and declares one. `andThen` is given two of its three
arguments, and the continuation writes one parameter where `a -> St b` declares
two.

-}
chainModule : Src.Module
chainModule =
    module_
        [ { name = "prog"
          , args = []
          , tipe = tSt tInt
          , body =
                callExpr (varExpr "andThen")
                    [ lambdaExpr [ pVar "a" ] (callExpr (varExpr "pure") [ varExpr "a" ])
                    , varExpr "tick"
                    ]
          }
        , testValueDef (callExpr (varExpr "prog") [ intExpr 0 ])
        ]


{-| A fixture whose definition is a bare reference to a global, declaring one
parameter and writing none: `d : St Int`, `d = tick`.
-}
bareGlobalModule : Src.Module
bareGlobalModule =
    module_
        [ { name = "d"
          , args = []
          , tipe = tSt tInt
          , body = varExpr "tick"
          }
        , testValueDef (callExpr (varExpr "d") [ intExpr 0 ])
        ]


{-| A fixture whose definition writes one parameter of the two it declares:
`d : Int -> St Int`, `d n = tick`.
-}
partialArityModule : Src.Module
partialArityModule =
    module_
        [ { name = "d"
          , args = [ pVar "n" ]
          , tipe = tLambda tInt (tSt tInt)
          , body = varExpr "tick"
          }
        , testValueDef (callExpr (varExpr "d") [ intExpr 1, intExpr 0 ])
        ]


{-| A fixture in which `prog` and its continuation already write every
parameter they declare:

    prog : St Int
    prog s0 =
        andThen (\a s1 -> a) tick s0

-}
saturatedContModule : Src.Module
saturatedContModule =
    module_
        [ { name = "prog"
          , args = [ pVar "s0" ]
          , tipe = tSt tInt
          , body =
                callExpr (varExpr "andThen")
                    [ lambdaExpr [ pVar "a", pVar "s1" ] (varExpr "a")
                    , varExpr "tick"
                    , varExpr "s0"
                    ]
          }
        , testValueDef (callExpr (varExpr "prog") [ intExpr 0 ])
        ]


{-| A fixture with a recursive definition that writes one parameter of the two
it declares, and whose body is a `case`:

    sequence : List (St Int) -> St (List Int)
    sequence actions =
        case actions of
            [ one ] ->
                pure []

            [ one, two ] ->
                andThen (\x -> sequence [ two ]) one

            _ ->
                andThen (\x -> pure []) tick

The decision tree reaches the `_` branch on two paths (an empty list, and a
list of three or more), so that branch is shared through the `case`'s `jumps`
list.

-}
sequenceModule : Src.Module
sequenceModule =
    module_
        [ { name = "sequence"
          , args = [ pVar "actions" ]
          , tipe =
                tLambda (tType "List" [ tSt tInt ])
                    (tSt (tType "List" [ tInt ]))
          , body =
                caseExpr (varExpr "actions")
                    [ ( pList [ pVar "one" ], callExpr (varExpr "pure") [ listExpr [] ] )
                    , ( pList [ pVar "one", pVar "two" ]
                      , callExpr (varExpr "andThen")
                            [ lambdaExpr [ pVar "x" ] (callExpr (varExpr "sequence") [ listExpr [ varExpr "two" ] ])
                            , varExpr "one"
                            ]
                      )
                    , ( pAnything
                      , callExpr (varExpr "andThen")
                            [ lambdaExpr [ pVar "x" ] (callExpr (varExpr "pure") [ listExpr [] ])
                            , varExpr "tick"
                            ]
                      )
                    ]
          }
        , testValueDef
            (callExpr (qualVarExpr "List" "length")
                [ callExpr (varExpr "sequence") [ listExpr [], intExpr 0 ] ]
            )
        ]


{-| A fixture with a self-tail-recursive definition that writes one parameter
of the two it declares:

    loop : Int -> St Int
    loop n =
        case n of
            other ->
                loop other

-}
tailDefModule : Src.Module
tailDefModule =
    module_
        [ { name = "loop"
          , args = [ pVar "n" ]
          , tipe = tLambda tInt (tSt tInt)
          , body =
                caseExpr (varExpr "n")
                    [ ( pVar "other", callExpr (varExpr "loop") [ varExpr "other" ] ) ]
          }
        , testValueDef (callExpr (varExpr "loop") [ intExpr 1, intExpr 0 ])
        ]


{-| A fixture whose value definition does expensive work before it builds
its function: `d : St Int`, `d = let big = expensive 1 in pure big`. Expanding
`d` would move `expensive 1` under the new parameter, computing it on every call
of `d` instead of once.
-}
expensiveLetModule : Src.Module
expensiveLetModule =
    module_
        [ { name = "d"
          , args = []
          , tipe = tSt tInt
          , body =
                letExpr
                    [ define "big" [] (callExpr (varExpr "expensive") [ intExpr 1 ]) ]
                    (callExpr (varExpr "pure") [ varExpr "big" ])
          }
        , testValueDef (callExpr (varExpr "d") [ intExpr 0 ])
        ]


{-| A fixture whose expensive work is in an argument rather than a `let`:
`d : St Int`, `d = pure (expensive 1)`.
-}
notCheapArgModule : Src.Module
notCheapArgModule =
    module_
        [ { name = "d"
          , args = []
          , tipe = tSt tInt
          , body = callExpr (varExpr "pure") [ callExpr (varExpr "expensive") [ intExpr 1 ] ]
          }
        , testValueDef (callExpr (varExpr "d") [ intExpr 0 ])
        ]


{-| `noSpineModule` without `d`: `testValue = 5`. Its `noSpine` count is the
baseline that `d` adds one to.
-}
noSpineControlModule : Src.Module
noSpineControlModule =
    module_ [ testValueDef (intExpr 5) ]


{-| A fixture whose definition has a type with no arrow, even after alias
expansion: `d : Int`, `d = 5`.
-}
noSpineModule : Src.Module
noSpineModule =
    module_
        [ { name = "d"
          , args = []
          , tipe = tInt
          , body = intExpr 5
          }
        , testValueDef (varExpr "d")
        ]
