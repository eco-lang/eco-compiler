module TestLogic.Monomorphize.LssFlowEdgeLossTest exposing (suite)

{-| FLOW EDGE LOSS — the pinned examples for the flow-repair arc
(plans/lss-var-chain-roots.md §9), settled by MEASUREMENT (three scratch
probes, 2026-09-01), not by the design narrative — which the probes partly
falsified, recorded here honestly.

ONE consumer, two producers. The measurements below were taken with every
settle repair OFF — what INFERENCE alone delivers. The settle flags were
fixed at their defaults and removed 2026-09-18, so that arm can no longer be
built in-tree: tests 1 and 2 went with it and their findings are recorded
here instead. Test 3, the shipped-defaults pin, is what remains executable.

    useStep f seed = (f seed) 2        -- consumes a 2-stage function

    -- producer C (1 declared param, nested body lambdas):
    mkAdderC u = \a -> \b -> a + b + u
    useStep (mkAdderC 1) 5             -- CALL-RESULT argument

    -- producer V (0 declared params — a VALUE whose body is the lambdas):
    mkAdder = \a -> \b -> a + b
    useStep mkAdder 5                  -- BARE-REFERENCE argument

MEASURED (probe rows, settle off):

    mkAdderC :: (.)-{5}->(.)-{1}->(.)-{2}->.      full spine of members
    useStep  :: ((.)-{1}->(.)-{2}->.)-...          ARRIVES INTACT (test 1)

    mkAdder  :: (.)-{4}->(.)-VAR->.                the PRODUCER'S OWN ROW
    useStep  :: ((.)-{4}->(.)-VAR->.)-...          shares the same var (test 2)

The falsified narrative: this is NOT a transport loss and NOT an
α-instantiation loss (the mono consumer loses it identically). Flow
delivered perfectly — there was NOTHING TO DELIVER: producer V's nested
lambdas are collapsed by mono-uncurry into ONE two-arg closure, and the
intermediate stage value (that closure with one argument supplied — a
LAMBDA-PAP) has no member identity in the l|/p|g| algebra. The paper never
meets this: it does not uncurry, so every λ keeps its own label. Eco's
missing piece at this fixture is a PRODUCER-SIDE identity for lambda-PAP
stages, not an edge.

What the deleted arm pinned: with settle off, producer C's CALL-RESULT
argument arrived all-set (test 1), while producer V's BARE-REFERENCE
argument arrived (set head, VAR interior) and the producer's own row carried
the same var (test 2) — the §9.1 point that the missing piece is a
PRODUCER-SIDE identity for lambda-PAP stages, not an edge.

The surviving test pins today's compensation: at shipped defaults the settle
machinery heals both rows consistently (the folded root head is pap-able, so
`varSucc` mints the successor member and writes it in every row).

POSTSCRIPT (2026-09-01): `lss.flowConnect` (LPartial + deTop,
lss-lpartial-asymmetric-join.md) flipped default-on and test 2's lost edge
healed at INFERENCE, exactly as this suite was built to detect. flowConnect
went default-OFF again on the 2026-09-18 solo census (byte-identical
artifact, −32.6 M dispatches) and was deleted with its flag the same day.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , callExpr
        , intExpr
        , lambdaExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pVar
        , tLambda
        , tType
        , varExpr
        )
import Compiler.Eco.Config as Config
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    Test.describe "flow edge loss — the §9 pinned examples"
        [ Test.test "BARE-REF arg at shipped defaults: settle heals both rows consistently" <|
            \() ->
                case runDefaults fixtureRef of
                    Ok g ->
                        let
                            xs =
                                useStepAnnos g
                        in
                        if List.any (\( h, r ) -> isSet h && isSet r) xs && not (List.any isVar (mkAdderInner g)) then
                            Expect.pass

                        else
                            Expect.fail
                                ("expected settle-healed sets in BOTH rows, got useStep "
                                    ++ describePairs xs
                                    ++ " / mkAdder inner "
                                    ++ describe (mkAdderInner g)
                                )

                    Err e ->
                        Expect.fail e
        ]



-- ====== FIXTURES ======


hInt : Src.Type
hInt =
    tType "Int" []


useStepDef : { name : String, args : List Src.Pattern, tipe : Src.Type, body : Src.Expr }
useStepDef =
    { name = "useStep"
    , args = [ pVar "f", pVar "seed" ]
    , tipe = tLambda (tLambda hInt (tLambda hInt hInt)) (tLambda hInt hInt)
    , body = callExpr (callExpr (varExpr "f") [ varExpr "seed" ]) [ intExpr 2 ]
    }


fixtureCall : Src.Module
fixtureCall =
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ { name = "mkAdderC"
          , args = [ pVar "u" ]
          , tipe = tLambda hInt (tLambda hInt (tLambda hInt hInt))
          , body =
                lambdaExpr [ pVar "a" ]
                    (lambdaExpr [ pVar "b" ]
                        (binopsExpr [ ( varExpr "a", "+" ), ( varExpr "b", "+" ) ] (varExpr "u"))
                    )
          }
        , useStepDef
        , { name = "testValue"
          , args = []
          , tipe = hInt
          , body = callExpr (varExpr "useStep") [ callExpr (varExpr "mkAdderC") [ intExpr 1 ], intExpr 5 ]
          }
        ]
        []
        []


fixtureRef : Src.Module
fixtureRef =
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ { name = "mkAdder"
          , args = []
          , tipe = tLambda hInt (tLambda hInt hInt)
          , body =
                lambdaExpr [ pVar "a" ]
                    (lambdaExpr [ pVar "b" ] (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")))
          }
        , useStepDef
        , { name = "testValue"
          , args = []
          , tipe = hInt
          , body = callExpr (varExpr "useStep") [ varExpr "mkAdder", intExpr 5 ]
          }
        ]
        []
        []



-- ====== HARNESS ======


runDefaults : Src.Module -> Result String Mono.MonoGraph
runDefaults srcModule =
    let
        d =
            Config.defaultLss
    in
    Pipeline.runSolverMonoWithLimits Config.defaultLimits
        { d | enabled = True }
        srcModule



-- ====== READERS ======


useStepAnnos : Mono.MonoGraph -> List ( Mono.LambdaSetAnno, Mono.LambdaSetAnno )
useStepAnnos (Mono.MonoGraph g) =
    Array.foldl
        (\entry acc ->
            case entry of
                Just ( Mono.Global _ name, monoType ) ->
                    if name == "useStep" then
                        case monoType of
                            Mono.MFunction _ _ ((Mono.MFunction _ headA _ (Mono.MFunction _ resA _ _)) :: _) _ ->
                                ( headA, resA ) :: acc

                            _ ->
                                acc

                    else
                        acc

                _ ->
                    acc
        )
        []
        g.registry.reverseMapping


{-| The producer's OWN inner-arrow annos (`mkAdder : Int -{outer}-> Int -{HERE}-> Int`).
-}
mkAdderInner : Mono.MonoGraph -> List Mono.LambdaSetAnno
mkAdderInner (Mono.MonoGraph g) =
    Array.foldl
        (\entry acc ->
            case entry of
                Just ( Mono.Global _ name, monoType ) ->
                    if name == "mkAdder" then
                        case monoType of
                            Mono.MFunction _ _ _ (Mono.MFunction _ inner _ _) ->
                                inner :: acc

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
    "[" ++ String.join ", " (List.map (\( h, r ) -> "(" ++ one h ++ " -> " ++ one r ++ ")") pairs) ++ "]"


describe : List Mono.LambdaSetAnno -> String
describe xs =
    "[" ++ String.join ", " (List.map one xs) ++ "]"


one : Mono.LambdaSetAnno -> String
one a =
    case a of
        Mono.LTop k ->
            "LTop " ++ Mono.topKindLabel k

        Mono.LVar n ->
            "LVar " ++ String.fromInt n

        Mono.LSet ms ->
            "LSet " ++ String.fromInt (List.length ms)

        Mono.LPartial ms ->
            "LPartial " ++ String.fromInt (List.length ms)
