module TestLogic.GlobalOpt.MonoInlineSimplifyPreserveSetsTest exposing (suite)

{-| Tests that `inline.preserveSets` stops the post-monomorphization inliner,
`Compiler.GlobalOpt.MonoInlineSimplify`, from replacing a partial call with a
new closure, and that the inliner counts each call it declines because of the
option. Without them the option could stop working, or the count could stop
counting.

A _strictly partial_ call passes at least one argument but fewer than the
callee has parameters. When the inliner inlines one, it _reshapes_ it: the call
becomes a new closure over the remaining parameters, with no lambda-set member,
so whatever member the callee's partial application would have carried is gone.
With `preserveSets` on, the inliner instead _declines_: it keeps the call, so
the partial application of the callee survives. Two counters in
`MonoInlineSimplify.Metrics` record this. `clearedMembers` is filled only when
`report` is on; its `RESHAPES|<site>` keys count reshapes per site (`tryInline`
for an inlined global, `beta` for an applied lambda literal), and its other keys
count reshapes whose callee carried a member. `declinedPreserveSets` counts
declines, and is counted whether or not `report` is on.

Every test except T3's monomorphizes its fixture as a default build does, with the solver
engine and lambda-set specialization on (the `monoGraph` of
`TestLogic.TestPipeline.runToGlobalOptLssOn`, taken before that pipeline's own
inliner runs), so the closures carry lambda-set members and the member-keyed
entries of `clearedMembers` are recorded. It then runs the inliner with
`report` on and one fixpoint iteration. A declined call is still there for any
later iteration to visit and count again, while a reshaped call is gone after
the first, so the single iteration is what lets a decline count be compared
with a reshape count.

There are three fixtures. `globalPartialModule` binds `g = add3 1 k`, two of
`add3`'s three arguments, and passes `g` to `List.map`; its tests use a size
budget of 50 instead of the default 10, so that `add3` is within it.
`hofPartialModule` binds `g = applyTwice inc k`, two of the three arguments of
a function that calls its function parameter, and its tests use a size budget
of 2 and a higher-order budget of 25, so that `applyTwice` is admitted only by
the higher-order budget, the one case `partialHof` changes.
`localPartialModule` passes `h 3`, where `h` is a let-bound two-parameter
lambda, to `List.map`.

The tests establish:

  - T1, with the option off on `globalPartialModule`: at least one reshape, a
    `RESHAPES|tryInline` entry, and at least one member-keyed entry, so the
    reshape does drop a callee's member.
  - T2, first test: with the option on, no member-keyed entries, no reshapes at
    any site, and a decline count equal to the reshape total of the run with
    the option off.
  - T2, second test: the option on gives a strictly lower `inlineCount` than
    the option off.
  - T3, on `hofPartialModule`, monomorphized with the substitution engine
    instead (see `withSubstMetrics`): with both options off the partial call
    is not reshaped (the higher-order candidate is exact-sites only); with
    `partialHof` on and `preserveSets` off it is; with both on there are no
    reshapes and at least one decline.
  - T4, on `localPartialModule`, with the option on: `declinedPreserveSets` is
    zero, so neither guarded site, the one in `tryInlineCall` nor the one
    before `betaReduce`, declined.

Among what is not tested: that a declined call keeps a lambda-set member in the
output graph; a decline at the guard before `betaReduce`, which no fixture
produces; runs of more than one iteration; and the code generated
afterwards.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , binopsExpr
        , callExpr
        , define
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pVar
        , qualVarExpr
        , tLambda
        , tType
        , varExpr
        )
import Compiler.Eco.Config as Config
import Compiler.GlobalOpt.MonoInlineSimplify as MonoInlineSimplify
import Dict
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The four groups of tests described in the module docstring.
-}
suite : Test
suite =
    Test.describe "MonoInlineSimplify preserveSets"
        [ Test.describe "T1 — flag off: the clearing arm fires (the denominator)"
            [ Test.test "a strictly-partial inline clears a member at tryInline" <|
                \_ ->
                    withMetrics (partialConfig False)
                        globalPartialModule
                        (\m ->
                            Expect.all
                                [ \_ ->
                                    if reshapesTotal m > 0 then
                                        Expect.pass

                                    else
                                        Expect.fail "expected the strictly-partial arm to reshape at least once"
                                , \_ ->
                                    if Dict.member "RESHAPES|tryInline" m.clearedMembers then
                                        Expect.pass

                                    else
                                        Expect.fail ("expected bySite to name tryInline, got " ++ bySite m)
                                , \_ ->
                                    if clearedCount m > 0 then
                                        Expect.pass

                                    else
                                        Expect.fail ("expected a reshape to drop a callee's member, got " ++ Debug.toString m.clearedMembers)
                                ]
                                ()
                        )
            ]
        , Test.describe "T2 — flag on: nothing clears, and the arm is accounted for"
            [ Test.test "cleared and reshapesTotal are zero, declinedPreserveSets takes over" <|
                \_ ->
                    withMetrics (partialConfig False)
                        globalPartialModule
                        (\off ->
                            withMetrics (partialConfig True)
                                globalPartialModule
                                (\on ->
                                    Expect.all
                                        [ \_ -> Expect.equal 0 (clearedCount on)
                                        , \_ -> Expect.equal 0 (reshapesTotal on)
                                        , \_ -> Expect.equal "" (bySite on)
                                        , \_ -> Expect.equal (reshapesTotal off) on.declinedPreserveSets
                                        ]
                                        ()
                                )
                        )
            , Test.test "the declined inline is the only thing given up" <|
                \_ ->
                    withMetrics (partialConfig False)
                        globalPartialModule
                        (\off ->
                            withMetrics (partialConfig True)
                                globalPartialModule
                                (\on ->
                                    if on.inlineCount < off.inlineCount then
                                        Expect.pass

                                    else
                                        Expect.fail
                                            ("expected fewer inlines with the flag on, got "
                                                ++ String.fromInt on.inlineCount
                                                ++ " vs "
                                                ++ String.fromInt off.inlineCount
                                            )
                                )
                        )
            ]
        , Test.describe "T3 — precedence over partialHof"
            [ Test.test "without partialHof the higher-order candidate is not reshaped" <|
                \_ ->
                    withSubstMetrics (hofConfig False False)
                        hofPartialModule
                        (\m -> Expect.equal "" (bySite m))
            , Test.test "partialHof alone reaches the clearing arm" <|
                \_ ->
                    withSubstMetrics (hofConfig True False)
                        hofPartialModule
                        (\m ->
                            if reshapesTotal m > 0 then
                                Expect.pass

                            else
                                Expect.fail "expected partialHof to leave the clearing arm reachable"
                        )
            , Test.test "with both on, preserveSets wins" <|
                \_ ->
                    withSubstMetrics (hofConfig True True)
                        hofPartialModule
                        (\m ->
                            Expect.all
                                [ \_ -> Expect.equal 0 (clearedCount m)
                                , \_ -> Expect.equal 0 (reshapesTotal m)
                                , \_ ->
                                    if m.declinedPreserveSets > 0 then
                                        Expect.pass

                                    else
                                        Expect.fail "expected the partial arm to decline, not mint"
                                ]
                                ()
                        )
            ]
        , Test.describe "T4 — the betaReduce partial arm is not reached"
            [ Test.test "a partially applied LAMBDA LITERAL declines nothing with the flag on" <|
                \_ ->
                    -- With the flag off the count is zero whatever the input,
                    -- since both sites that bump it check the flag first.
                    withMetrics (partialConfig True)
                        localPartialModule
                        (\on -> Expect.equal 0 on.declinedPreserveSets)
            ]
        ]



-- ============================================================================
-- HELPERS
-- ============================================================================


{-| Returns the total of the member-keyed entries of `clearedMembers`, which
count reshapes whose callee carried a lambda-set member. The `RESHAPES|` totals
are left out.
-}
clearedCount : MonoInlineSimplify.Metrics -> Int
clearedCount m =
    Dict.foldl
        (\k c a ->
            if String.startsWith "RESHAPES|" k then
                a

            else
                a + c
        )
        0
        m.clearedMembers


{-| Returns the total of the `RESHAPES|<site>` entries of `clearedMembers`: the
number of reshapes at every site, whether or not the callee carried a member.
It is zero when `report` is off, because the entries are then not recorded.
-}
reshapesTotal : MonoInlineSimplify.Metrics -> Int
reshapesTotal m =
    Dict.foldl
        (\k c a ->
            if String.startsWith "RESHAPES|" k then
                a + c

            else
                a
        )
        0
        m.clearedMembers


{-| Returns the `RESHAPES|<site>` entries of `clearedMembers` as `site:count`
pairs joined by commas, in key order, or the empty string when there are none.
-}
bySite : MonoInlineSimplify.Metrics -> String
bySite m =
    Dict.toList m.clearedMembers
        |> List.filter (\( k, _ ) -> String.startsWith "RESHAPES|" k)
        |> List.map (\( k, c ) -> String.dropLeft 9 k ++ ":" ++ String.fromInt c)
        |> String.join ","


{-| Returns the default inline configuration with `preserveSets` as given, a
`postMonoThreshold` of 50 so that `add3` is within the size budget, `report` on
so that `clearedMembers` is filled, and one fixpoint iteration.
-}
partialConfig : Bool -> Config.InlineConfig
partialConfig preserveSets =
    let
        base =
            Config.default.inline
    in
    { base
        | postMonoThreshold = 50
        , report = True
        , postMonoFixpointIterations = 1
        , preserveSets = preserveSets
    }


{-| Returns the configuration of the T3 tests, with `partialHof` and
`preserveSets` as given: `report` on, one fixpoint iteration, a
`postMonoThreshold` of 2 and a `hofThreshold` of 25.

`partialHof` lets a candidate admitted only by the higher-order budget inline
at a strictly partial call, which without it such a candidate never does. The
cost of `applyTwice` is above 2 and within 25, and its body calls its function
parameter, so it is admitted only by the higher-order budget.

-}
hofConfig : Bool -> Bool -> Config.InlineConfig
hofConfig partialHof preserveSets =
    let
        base =
            Config.default.inline
    in
    { base
        | postMonoThreshold = 2
        , hofThreshold = 25
        , report = True
        , postMonoFixpointIterations = 1
        , preserveSets = preserveSets
        , partialHof = partialHof
    }


{-| Monomorphizes `srcModule` with lambda-set specialization on (the
`monoGraph` of `runToGlobalOptLssOn`, from before that pipeline's own inliner
runs), inlines that graph with `inlineConfig`, and returns `check` applied to
the inliner's metrics. If the pipeline returns an error, the test fails with
its message.
-}
withMetrics : Config.InlineConfig -> Src.Module -> (MonoInlineSimplify.Metrics -> Expect.Expectation) -> Expect.Expectation
withMetrics inlineConfig srcModule check =
    case Pipeline.runToGlobalOptLssOn srcModule of
        Err msg ->
            Expect.fail msg

        Ok artifacts ->
            check (Tuple.second (MonoInlineSimplify.optimize inlineConfig artifacts.monoGraph))


{-| Like `withMetrics`, but monomorphizes with the substitution engine
(`runToMono`), under which `applyTwice` keeps its function parameter `f` and
calls it. With lambda-set specialization on, `hofPartialModule`'s `applyTwice`
is not admitted by the higher-order budget (its specialization no longer calls
a function parameter), so the T3 tests use this engine. It records no
member-keyed entries of `clearedMembers`.
-}
withSubstMetrics : Config.InlineConfig -> Src.Module -> (MonoInlineSimplify.Metrics -> Expect.Expectation) -> Expect.Expectation
withSubstMetrics inlineConfig srcModule check =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail msg

        Ok artifacts ->
            check (Tuple.second (MonoInlineSimplify.optimize inlineConfig artifacts.monoGraph))



-- ============================================================================
-- FIXTURES
-- ============================================================================


{-| The source type `Int`.
-}
tInt : Src.Type
tInt =
    tType "Int" []


{-| The source type `List Int`.
-}
tIntList : Src.Type
tIntList =
    tType "List" [ tInt ]


{-| The definition `add3 a b c = a + b + c`, the global whose partial call
`globalPartialModule` makes.
-}
add3Def : TypedDef
add3Def =
    { name = "add3"
    , args = [ pVar "a", pVar "b", pVar "c" ]
    , tipe = tLambda tInt (tLambda tInt (tLambda tInt tInt))
    , body = binopsExpr [ ( varExpr "a", "+" ), ( varExpr "b", "+" ) ] (varExpr "c")
    }


{-| A module named `Test` holding `add3`, a `partialShape k xs` that binds
`g = add3 1 k` and returns `List.map g xs`, and a `testValue` of
`partialShape 4 [ 1, 2, 3 ]`.
-}
globalPartialModule : Src.Module
globalPartialModule =
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ add3Def
        , { name = "partialShape"
          , args = [ pVar "k", pVar "xs" ]
          , tipe = tLambda tInt (tLambda tIntList tIntList)
          , body =
                letExpr
                    [ define "g" [] (callExpr (varExpr "add3") [ intExpr 1, varExpr "k" ]) ]
                    (callExpr (qualVarExpr "List" "map") [ varExpr "g", varExpr "xs" ])
          }
        , { name = "testValue"
          , args = []
          , tipe = tIntList
          , body = callExpr (varExpr "partialShape") [ intExpr 4, listExpr [ intExpr 1, intExpr 2, intExpr 3 ] ]
          }
        ]
        []
        []


{-| A module named `Test` holding `inc n = n + 1`,
`applyTwice f a b = f a + f b`, a `hofShape k xs` that binds
`g = applyTwice inc k` and returns `List.map g xs`, and a `testValue` of
`hofShape 4 [ 1, 2, 3 ]`.
-}
hofPartialModule : Src.Module
hofPartialModule =
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ { name = "inc"
          , args = [ pVar "n" ]
          , tipe = tLambda tInt tInt
          , body = binopsExpr [ ( varExpr "n", "+" ) ] (intExpr 1)
          }
        , { name = "applyTwice"
          , args = [ pVar "f", pVar "a", pVar "b" ]
          , tipe = tLambda (tLambda tInt tInt) (tLambda tInt (tLambda tInt tInt))
          , body =
                binopsExpr [ ( callExpr (varExpr "f") [ varExpr "a" ], "+" ) ]
                    (callExpr (varExpr "f") [ varExpr "b" ])
          }
        , { name = "hofShape"
          , args = [ pVar "k", pVar "xs" ]
          , tipe = tLambda tInt (tLambda tIntList tIntList)
          , body =
                letExpr
                    [ define "g" [] (callExpr (varExpr "applyTwice") [ varExpr "inc", varExpr "k" ]) ]
                    (callExpr (qualVarExpr "List" "map") [ varExpr "g", varExpr "xs" ])
          }
        , { name = "testValue"
          , args = []
          , tipe = tIntList
          , body = callExpr (varExpr "hofShape") [ intExpr 4, listExpr [ intExpr 1, intExpr 2, intExpr 3 ] ]
          }
        ]
        []
        []


{-| A module named `Test` holding a `localPartial k xs` that binds `h` to
`\a b -> a * b + k` and returns `List.map (h 3) xs`, and a `testValue` of
`localPartial 7 [ 1, 2 ]`.

The call `h 3` would be a strictly partial application of a lambda literal if
the lambda were substituted for `h`, but the inliner substitutes a let-bound
lambda only at a call with at least as many arguments as it has parameters.

-}
localPartialModule : Src.Module
localPartialModule =
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ { name = "localPartial"
          , args = [ pVar "k", pVar "xs" ]
          , tipe = tLambda tInt (tLambda tIntList tIntList)
          , body =
                letExpr
                    [ define "h"
                        []
                        (lambdaExpr [ pVar "a", pVar "b" ]
                            (binopsExpr [ ( binopsExpr [ ( varExpr "a", "*" ) ] (varExpr "b"), "+" ) ] (varExpr "k"))
                        )
                    ]
                    (callExpr (qualVarExpr "List" "map")
                        [ callExpr (varExpr "h") [ intExpr 3 ], varExpr "xs" ]
                    )
          }
        , { name = "testValue"
          , args = []
          , tipe = tIntList
          , body = callExpr (varExpr "localPartial") [ intExpr 7, listExpr [ intExpr 1, intExpr 2 ] ]
          }
        ]
        []
        []
