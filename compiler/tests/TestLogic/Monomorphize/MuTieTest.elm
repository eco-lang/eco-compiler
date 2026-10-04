module TestLogic.Monomorphize.MuTieTest exposing (suite)

{-| Checks that the solver engine, with lambda-set specialization on, makes a
bounded number of specializations of a recursive function that passes a new
closure to itself on every call. It guards against a change to how lambda
members are identified letting such a function fan out into specializations
without end.

With lambda-set specialization on, every function type carries a lambda set,
which names, where they are known, the function values (_members_) that can flow
through it. A lambda translated inside a specialization gets a member id
qualified by the type that specialization was created for, with its lambda sets
widened, or by the specialization's numeric id when that widened type was not
captured at its creation. When the specialization passes that lambda to a
recursive call, the qualified member is part of the type the call demands, so
the call can key a new specialization of the same function. If translating that
one minted the lambda under a different qualifier, that member could key a
third, and so on. The Elm type stays `Int -> Int` throughout; only the member
ids differ. This cycle is the _qualification spiral_. Two things in
`Compiler.MonoSolver.Engine` stop it. Two specializations that differ only in
their lambda sets, with both widened types recorded, give the lambda the same
id. And where the id the specialization's demand already carries for the same
lambda differs from the one the mint would give, the _μ-tie_ reuses the
demand-carried id instead. Member ids reused by a μ-tie are listed in the
graph's `lssBlockedMembers`.

The fixture is one module, `Test`:

    loop : Int -> (Int -> Int) -> Int
    loop n f =
        if n <= 0 then
            f 0

        else
            1 + loop (n - 1) (\x -> f x + 1)

    testValue =
        loop 3 (\x -> x)

It is monomorphized with the default watchdog limits and with
`Config.defaultLss`, except that the per-global specialization budget is
pinned at 64 and the largest lambda set at 8 members. Both default to 0,
meaning no limit. Past the budget, a new demand is keyed by its type with the
lambda sets widened, and since the type of `loop` never changes, that bounds
the number of its specializations even if the spiral does not close.

The one test, "the fan-out closes at the family's second member", checks that
the pipeline succeeds and that at most three specializations of `loop`
survive pruning in the graph's registry.

Among what is not tested: which of the two mechanisms closed the spiral, the
contents of `lssBlockedMembers` (counted in `Facts` but never asserted), a run
with the default unlimited budget, and the substitution engine.

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


{-| The suite: one test that `run` succeeds and leaves at most three
specializations of `loop`.
-}
suite : Test
suite =
    Test.describe "LSS_018 μ-tie (qualification spiral)"
        [ Test.test "the fan-out closes at the family's second member" <|
            \() ->
                case run of
                    Err msg ->
                        Expect.fail msg

                    Ok facts ->
                        Expect.all
                            [ \f ->
                                if f.loopSpecs <= 3 then
                                    Expect.pass

                                else
                                    Expect.fail
                                        ("expected the tie to close the fan-out at the family's second member, got loopSpecs="
                                            ++ String.fromInt f.loopSpecs
                                        )
                            ]
                            facts
        ]



-- ====== HARNESS ======


{-| What the test reads off the monomorphized graph.

`blockedCount` is the number of member ids in `lssBlockedMembers`; no
assertion checks it. `loopSpecs` counts the registry entries for a global
named `loop` that survive pruning.

-}
type alias Facts =
    { blockedCount : Int
    , loopSpecs : Int
    }


{-| The number of specializations of one global past which new demands are
keyed with widened lambda sets, pinned so that the number of `loop`
specializations stays bounded even if the spiral does not close. The default
is 0, meaning no budget.
-}
pinnedBudget : Int
pinnedBudget =
    64


{-| The `Facts` of `spiralModule` monomorphized by the solver engine with
lambda-set specialization on, `pinnedBudget` as the per-global budget and at
most 8 members in a lambda set, or the message of the stage that failed.
-}
run : Result String Facts
run =
    let
        defaults =
            Config.defaultLss
    in
    Pipeline.runSolverMonoWithLimits
        Config.defaultLimits
        { defaults | enabled = True, maxSpecsPerGlobal = pinnedBudget, maxSetSize = 8 }
        spiralModule
        |> Result.map factsOf


{-| Reads the `Facts` from a monomorphized graph. A registry entry counts
toward `loopSpecs` when its global is named `loop`, whatever its module.
-}
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


{-| The test program: module `Test`, holding `loop` and `testValue`.
-}
spiralModule : Src.Module
spiralModule =
    makeModuleWithTypedDefs "Test" [ loopDef, testValueDef ]


{-| The definition of `loop`, which calls itself with a new lambda wrapping
its own function argument.

The `1 +` keeps the recursive call out of tail position. A tail call is
translated as a jump within the current specialization and asks for no new
one, so the spiral could not start.

-}
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


{-| The definition of `testValue`, `loop 3 (\x -> x)`. The test pipeline's
synthetic `main` refers to `testValue`, which is what makes `loop` reachable.
-}
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
