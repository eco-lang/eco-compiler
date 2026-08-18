module TestLogic.Monomorphize.MuTieTest exposing (suite)

{-| LSS_018 — the μ-tie that closes the qualification spiral
(`plans/lss-fidelity-1-watchdogs-budget-accounting.md` §2).

**Why this fixture exists.** The self-compile census measured the eligible
population at ZERO (Run J: `muTied=0`), so no production workload in the
tree exercises the tie. This module builds the spiral deliberately:

    loop : Int -> (Int -> Int) -> Int
    loop n f =
        if n <= 0 then f 0 else 1 + loop (n - 1) (\x -> f x + 1)

The `1 +` is load-bearing: it keeps the self-call OUT of tail position. A
tail-recursive self-call is TCO'd into a loop and never enqueues a
specialization at all, so the spiral cannot form (measured: the tail-call
form yields exactly 1 spec of `loop`, flag either way).

Under all-globals keying, spec S1 of `loop` mints the wrapper lambda `L` as
the fork-qualified member `Q(L,S1)` (LSS_017). That member rides the
recursive call's demand, so the callee keys a NEW spec S2 whose stored
demand carries `Q(L,S1)`; translating S2 re-mints the SAME source lambda,
and without the tie it becomes `Q(L,S2)` — which keys S3, and so on. The
TYPE never changes (`Int -> Int` throughout): the fan-out is driven purely
by member identity, which is precisely the specs→qualified-members→keys
spiral of the fork plan §6.5.

Flag-off, only `maxSpecsPerGlobal` stops it. Flag-on, S2 reuses `Q(L,S1)`,
its outgoing demand equals its incoming one, the registry probe hits, and
the family closes at its second member — the termination property LSS_018
claims, with the budget demoted to fan-out policy.

The assertions are on OBSERVABLE graph state: `lssBlockedMembers` (the
exported tied set, which AbiCloning force-blocks so a tied member can never
rep-stamp — plan §2.4) and the per-global spec count in the registry.
-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , binopsExpr
        , callExpr
        , ifExpr
        , intExpr
        , lambdaExpr
        , makeModuleWithTypedDefs
        , pVar
        , tLambda
        , tType
        , varExpr
        )
import Compiler.Eco.Config as Config
import Dict
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    Test.describe "LSS_018 μ-tie (qualification spiral)"
        [ Test.test "flag OFF: the spiral fans out and nothing is tied" <|
            \() ->
                case run False of
                    Err msg ->
                        Expect.fail msg

                    Ok facts ->
                        Expect.all
                            [ \f ->
                                Expect.equal 0
                                    f.blockedCount
                            , \f ->
                                -- The spiral is real AND the budget is its
                                -- ONLY terminator (plan §2.1): measured 65
                                -- specs of `loop` = maxSpecsPerGlobal (64)
                                -- + the seed, where the TYPE alone needs 1.
                                if f.loopSpecs >= Config.defaultLss.maxSpecsPerGlobal then
                                    Expect.pass

                                else
                                    Expect.fail
                                        ("expected the flag-off spiral to run to the budget, got loopSpecs="
                                            ++ String.fromInt f.loopSpecs
                                        )
                            ]
                            facts
        , Test.test "flag ON: the family is tied, blocked, and the fan-out closes" <|
            \() ->
                case run True of
                    Err msg ->
                        Expect.fail msg

                    Ok facts ->
                        Expect.all
                            [ \f ->
                                if f.blockedCount >= 1 then
                                    Expect.pass

                                else
                                    Expect.fail
                                        "expected at least one μ-tied member exported in lssBlockedMembers"
                            , \f ->
                                -- Measured 2: the family closes at its
                                -- SECOND member (S2 reuses Q(L,S1), so its
                                -- outgoing demand equals its incoming one
                                -- and the registry probe hits) — termination
                                -- independent of maxSpecsPerGlobal.
                                if f.loopSpecs <= 3 then
                                    Expect.pass

                                else
                                    Expect.fail
                                        ("expected the tie to close the fan-out at the family's second member, got loopSpecs="
                                            ++ String.fromInt f.loopSpecs
                                        )
                            ]
                            facts
        , Test.test "the tie strictly reduces fan-out (off vs on, same fixture)" <|
            \() ->
                case ( run False, run True ) of
                    ( Ok off, Ok on ) ->
                        if on.loopSpecs < off.loopSpecs then
                            Expect.pass

                        else
                            Expect.fail
                                ("μ-tie did not reduce specialization fan-out: off="
                                    ++ String.fromInt off.loopSpecs
                                    ++ " on="
                                    ++ String.fromInt on.loopSpecs
                                )

                    ( Err e, _ ) ->
                        Expect.fail e

                    ( _, Err e ) ->
                        Expect.fail e
        ]



-- ====== HARNESS ======


type alias Facts =
    { blockedCount : Int
    , loopSpecs : Int
    }


run : Bool -> Result String Facts
run muTie =
    let
        defaults =
            Config.defaultLss
    in
    Pipeline.runSolverMonoWithLimits
        Config.defaultLimits
        -- keyed = True (the shipping default) is what routes the mints
        -- through fork qualification in the first place.
        { defaults | enabled = True, keyed = True, muTie = muTie }
        spiralModule
        |> Result.map factsOf


factsOf : Mono.MonoGraph -> Facts
factsOf (Mono.MonoGraph g) =
    { blockedCount = Dict.size g.lssBlockedMembers
    , loopSpecs =
        Array.foldl
            (\entry acc ->
                case entry of
                    Just ( Mono.Global _ name, _ ) ->
                        if name == "loop" then
                            acc + 1

                        else
                            acc

                    _ ->
                        acc
            )
            0
            g.registry.reverseMapping
    }



-- ====== FIXTURE ======


{-| See the module doc: a NON-tail-recursive HOF that passes a NEW closure
over its own function parameter on every recursive call. The type is
invariant (`Int -> Int`); only the lambda-set member changes, so any
fan-out here is pure qualification spiral.
-}
spiralModule : Src.Module
spiralModule =
    makeModuleWithTypedDefs "Test" [ loopDef, testValueDef ]


loopDef : TypedDef
loopDef =
    { name = "loop"
    , args = [ pVar "n", pVar "f" ]
    , tipe =
        tLambda (tType "Int" [])
            (tLambda (tLambda (tType "Int" []) (tType "Int" []))
                (tType "Int" [])
            )
    , body =
        ifExpr
            (binopsExpr [ ( varExpr "n", "<=" ) ] (intExpr 0))
            (callExpr (varExpr "f") [ intExpr 0 ])
            -- `1 + …` keeps the self-call out of TAIL position: a tail
            -- self-call is TCO'd to a loop and enqueues no spec, so the
            -- spiral would never form (verified: 1 spec, both flag states).
            (binopsExpr [ ( intExpr 1, "+" ) ]
                (callExpr (varExpr "loop")
                    [ binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1)
                    , lambdaExpr [ pVar "x" ]
                        (binopsExpr
                            [ ( callExpr (varExpr "f") [ varExpr "x" ], "+" ) ]
                            (intExpr 1)
                        )
                    ]
                )
            )
    }


testValueDef : TypedDef
testValueDef =
    { name = "testValue"
    , args = []
    , tipe = tType "Int" []
    , body =
        callExpr (varExpr "loop")
            [ intExpr 3
            , lambdaExpr [ pVar "x" ] (varExpr "x")
            ]
    }
