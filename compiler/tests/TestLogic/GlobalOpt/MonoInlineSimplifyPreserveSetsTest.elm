module TestLogic.GlobalOpt.MonoInlineSimplifyPreserveSetsTest exposing (suite)

{-| `inline.preserveSets` — the post-mono inliner with no set-clearing site
(`plans/pre-mono-lss-transforms-02-inline-preserve-sets.md` §7.1).

The pass has exactly ONE reshape that clears an LSS member identity:
`tryInlineCall`'s strictly-partial arm, which mints a residual `MonoClosure`
with `lssMember = Nothing` and a `topSynth` type. With the flag on that arm
DECLINES, leaving the callee's PAP — a stampable `p|<global>|k` member — in
place.

These tests pin the instrument as well as the behaviour: a `cleared=0` is only
meaningful next to a `declinedPreserveSets` that says the arm WAS reached, so
T1 establishes the denominator and T2 asserts the exchange.

**Every arm runs at `postMonoFixpointIterations = 1`,** which is what makes the counts
comparable. A reshape CONSUMES its call site, so it is counted once however many
iterations run; a decline LEAVES the site in place, so the fixpoint re-visits it
and `declinedPreserveSets` counts it again (measured on the q2probe fixture:
1 / 2 / 2 declines at FPI 1 / 2 / 3 against a flag-off `cleared` of 1). The
plan's §3.3 equality therefore holds per ITERATION, not per run — the general
relation is `declinedPreserveSets >= cleared(flag off)`.

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
                                , \_ -> Expect.equal 0 m.declinedPreserveSets
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

                                        -- The exchange, per iteration: every
                                        -- reshape the flag-off arm performed is
                                        -- a decline in the flag-on arm.
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
                                    -- Fewer inlines, and strictly fewer: the
                                    -- flag only ever removes work from the pass.
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
            [ Test.test "partialHof alone reaches the clearing arm" <|
                \_ ->
                    withMetrics (partialHofConfig False)
                        globalPartialModule
                        (\m ->
                            if reshapesTotal m > 0 then
                                Expect.pass

                            else
                                Expect.fail "expected partialHof to leave the clearing arm reachable"
                        )
            , Test.test "with both on, preserveSets wins" <|
                \_ ->
                    withMetrics (partialHofConfig True)
                        globalPartialModule
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
            [ Test.test "a partially applied LAMBDA LITERAL declines nothing in either arm" <|
                \_ ->
                    -- Documents the measured fact behind guarding that arm
                    -- anyway: `bySite` never names `beta` on the self-compile
                    -- or here. If a future change makes it reachable, this test
                    -- is what says so.
                    withMetrics (partialConfig False)
                        localPartialModule
                        (\off ->
                            withMetrics (partialConfig True)
                                localPartialModule
                                (\on ->
                                    Expect.equal ( 0, 0 ) ( off.declinedPreserveSets, on.declinedPreserveSets )
                                )
                        )
            ]
        ]



-- ============================================================================
-- HELPERS
-- ============================================================================


{-| Sum of the per-reshape entries (the members actually lost).
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


{-| Sum of the `RESHAPES|<site>` totals — every reshape, member-bearing or not.
This is the arm's own fire count, so it is the denominator T1 establishes.
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


bySite : MonoInlineSimplify.Metrics -> String
bySite m =
    Dict.toList m.clearedMembers
        |> List.filter (\( k, _ ) -> String.startsWith "RESHAPES|" k)
        |> List.map (\( k, c ) -> String.dropLeft 9 k ++ ":" ++ String.fromInt c)
        |> String.join ","


{-| `postMonoThreshold = 50` so the three-parameter global is a candidate at all (it
costs more than the default budget), `report = True` so the reshape census
collects, and `postMonoFixpointIterations = 1` so decline counts are per-iteration
exact (see the module doc).
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


{-| T3: `partialHof` exists to FORCE the clearing arm; `preserveSets` must win.
-}
partialHofConfig : Bool -> Config.InlineConfig
partialHofConfig preserveSets =
    let
        base =
            partialConfig preserveSets
    in
    { base | partialHof = True }


withMetrics : Config.InlineConfig -> Src.Module -> (MonoInlineSimplify.Metrics -> Expect.Expectation) -> Expect.Expectation
withMetrics inlineConfig srcModule check =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail msg

        Ok artifacts ->
            check (Tuple.second (MonoInlineSimplify.optimize inlineConfig artifacts.monoGraph))



-- ============================================================================
-- FIXTURES
-- ============================================================================


tInt : Src.Type
tInt =
    tType "Int" []


tIntList : Src.Type
tIntList =
    tType "List" [ tInt ]


{-| `add3 a b c = a + b + c` — the partial-inline candidate.
-}
add3Def : TypedDef
add3Def =
    { name = "add3"
    , args = [ pVar "a", pVar "b", pVar "c" ]
    , tipe = tLambda tInt (tLambda tInt (tLambda tInt tInt))
    , body = binopsExpr [ ( varExpr "a", "+" ), ( varExpr "b", "+" ) ] (varExpr "c")
    }


{-| The clearing shape: a partial application of a GLOBAL (2 of 3) escaping into
a HOF, so it must survive as a value rather than being merged into a saturated
call. This is `plans/…-02` §5's shape (a).
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


{-| T4's shape (c): a partially applied LAMBDA LITERAL, which is what would
reach `betaReduce`'s partial arm if anything did.
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
