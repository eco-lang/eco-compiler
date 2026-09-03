module TestLogic.Monomorphize.LssVarSuccTest exposing (suite)

{-| VAR SUCCESSOR WRITES — `lss.varSucc` (plans/lss-var-chain-roots.md §3
Phase 1).

A position holding a pap-able singleton `{p|X|k}` whose result-arrow slot
is flex is the P0's largest sound class (1,030 direct): the only value
obtainable by further-partially-applying a `p|X|k` value is `p|X|k+j`, so
the settle sweep may write the successor member — strictly WITHIN declared
arity (the arrow past the last parameter belongs to the body, LSS_013).

Fixture: `add3` (arity 3) partially applied to one arg and passed to a
HOF. The HOF's param row then holds the head `{p|add3|1}` (the demand
head-enrichment that DOES land today) with a flex `/r` (the deeper write
that does NOT — argFeedback's head-only gap). Off-vs-on DIFFERENTIAL: the
`/a0/r` slot flips var → singleton successor.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , callExpr
        , intExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pVar
        , tLambda
        , tType
        , tVar
        , varExpr
        )
import Compiler.Eco.Config as Config
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    Test.describe "lss.varSucc — PAP successor settle writes"
        -- FIXTURE FINDING (recorded in plans/lss-var-chain-roots.md §5.1):
        -- a ONE-MODULE pipeline fixture CANNOT manufacture the flag's
        -- target class — in-item unification plus the default-on
        -- producer-side machinery (papMembers head + injTotal L2 deep-PAP
        -- completion) cover every /r spine this fixture can express, at
        -- MONO or POLY consumer types alike (both variants measured
        -- all-set on the off arm). The corpus battery's counters + named
        -- cells are the differential; the unit pin here is the flip side:
        -- the settle pass is ADDITIVE-ONLY — on a fully-covered fixture it
        -- must change NOTHING.
        [ Test.test "1. no-op on a fully-covered fixture (additive-only pin)" <|
            \() ->
                case ( runWith False fixture, runWith True fixture ) of
                    ( Ok offG, Ok onG ) ->
                        case ( stepAnnos offG, stepAnnos onG ) of
                            ( [], _ ) ->
                                Expect.fail "no useStep /a0 arrow-result position — fixture broken"

                            ( offA, onA ) ->
                                if List.any (\( h, r ) -> not (isSet h) || not (isSet r)) offA then
                                    Expect.fail
                                        ("fixture no longer fully covered off-arm (in-item transport regressed?): "
                                            ++ describePairs offA
                                        )

                                else if offA == onA then
                                    Expect.pass

                                else
                                    Expect.fail
                                        ("varSucc CHANGED a covered fixture: off "
                                            ++ describePairs offA
                                            ++ " vs on "
                                            ++ describePairs onA
                                        )

                    ( Err e, _ ) ->
                        Expect.fail e

                    ( _, Err e ) ->
                        Expect.fail e
        ]



-- ====== FIXTURE ======


hInt : Src.Type
hInt =
    tType "Int" []


fixture : Src.Module
fixture =
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ { name = "add3"
          , args = [ pVar "a", pVar "b", pVar "c" ]
          , tipe = tLambda hInt (tLambda hInt (tLambda hInt hInt))
          , body =
                binopsExpr [ ( varExpr "a", "+" ), ( varExpr "b", "+" ) ] (varExpr "c")
          }
        , -- POLYMORPHIC on purpose: the demand instantiates the scheme
          -- FRESH (LSS_006) and `argUnifyVar` enriches the arg's HEAD only,
          -- so /a0/r stays a never-written flex — the corpus's exact
          -- argument-spine class. (A monomorphic useStep unifies in-item
          -- and the /r arrives for free — first fixture's mistake.)
          { name = "useStep"
          , args = [ pVar "g", pVar "seed" ]
          , tipe = tLambda (tLambda (tVar "x") (tLambda hInt hInt)) (tLambda (tVar "x") hInt)
          , body = callExpr (varExpr "g") [ varExpr "seed", intExpr 2 ]
          }
        , { name = "testValue"
          , args = []
          , tipe = hInt
          , body = callExpr (varExpr "useStep") [ callExpr (varExpr "add3") [ intExpr 1 ], intExpr 5 ]
          }
        ]
        []
        []



-- ====== HARNESS ======


runWith : Bool -> Src.Module -> Result String Mono.MonoGraph
runWith varSucc srcModule =
    let
        defaults =
            Config.defaultLss
    in
    Pipeline.runSolverMonoWithLimits Config.defaultLimits
        { defaults | enabled = True, keyed = True, settle = (\st -> { st | varSucc = varSucc }) defaults.settle }
        srcModule



-- ====== READERS ======


{-| useStep's registry rows at `/a0`: the (head anno, result-arrow anno)
pair of the 2-stage function parameter.
-}
stepAnnos : Mono.MonoGraph -> List ( Mono.LambdaSetAnno, Mono.LambdaSetAnno )
stepAnnos (Mono.MonoGraph g) =
    Array.foldl
        (\entry acc ->
            case entry of
                Just ( Mono.Global _ name, monoType ) ->
                    if name == "useStep" then
                        case monoType of
                            Mono.MFunction _ _ ((Mono.MFunction _ headA [ _ ] (Mono.MFunction _ succA _ _)) :: _) _ ->
                                ( headA, succA ) :: acc

                            _ ->
                                acc

                    else
                        acc

                _ ->
                    acc
        )
        []
        g.registry.reverseMapping


isVar : Mono.LambdaSetAnno -> Bool
isVar a =
    case a of
        Mono.LVar _ ->
            True

        _ ->
            False


isSet : Mono.LambdaSetAnno -> Bool
isSet a =
    case a of
        Mono.LSet (_ :: _) ->
            True

        _ ->
            False


describePairs : List ( Mono.LambdaSetAnno, Mono.LambdaSetAnno ) -> String
describePairs pairs =
    "["
        ++ String.join ", "
            (List.map (\( h, r ) -> "(" ++ describeAnno h ++ " -> " ++ describeAnno r ++ ")") pairs)
        ++ "]"


describeAnno : Mono.LambdaSetAnno -> String
describeAnno a =
    case a of
        Mono.LTop k ->
            "LTop " ++ Mono.topKindLabel k

        Mono.LVar n ->
            "LVar " ++ String.fromInt n

        Mono.LSet ms ->
            "LSet " ++ String.fromInt (List.length ms)

        Mono.LPartial ms ->
            "LPartial " ++ String.fromInt (List.length ms)
