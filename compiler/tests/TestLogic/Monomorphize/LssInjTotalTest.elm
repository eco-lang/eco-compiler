module TestLogic.Monomorphize.LssInjTotalTest exposing (suite)

{-| INJECTION-TOTALITY COMPLETION — `lss.injTotal`
(plans/lss-coverage-four-levers.md).

Three levers under one flag: L1 completion-join head re-stamp, L2 deep-PAP
successor completion, L3 the Accessor/bare-VarKernel argument arms. L1's
sharpest differentials live at E2E scale (the kernel-ABI ⊤ needs kernel-bodied
defs — see LssGapReturnedClosure/LssGapPapDeepArg flag-on); this suite pins
the fixture-testable levers as off-vs-on DIFFERENTIALS.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( accessorExpr
        , binopsExpr
        , callExpr
        , intExpr
        , makeModuleWithTypedDefs
        , pVar
        , tLambda
        , tRecord
        , tType
        , varExpr
        )
import Compiler.Eco.Config as Config
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    Test.describe "lss.injTotal — L2 deep-PAP + L3 accessor arm"
        [ Test.test "1. L2 DIFFERENTIAL: deep-PAP /a0/r flips LVar -> LSet" <|
            \() ->
                case ( runWith False fixture, runWith True fixture ) of
                    ( Ok offG, Ok onG ) ->
                        case ( a0rAnnos "useIt" offG, a0rAnnos "useIt" onG ) of
                            ( [], _ ) ->
                                Expect.fail "no /a0/r for useIt — fixture broken"

                            ( offA, onA ) ->
                                if not (List.all isVar offA) then
                                    Expect.fail ("off-arm /a0/r expected LVar, got " ++ describe offA)

                                else if List.all isSingleton onA then
                                    Expect.pass

                                else
                                    Expect.fail ("on-arm /a0/r expected SINGLETON, got " ++ describe onA)

                    ( Err e, _ ) ->
                        Expect.fail e

                    ( _, Err e ) ->
                        Expect.fail e
        , Test.test "2. L2 PRODUCER CONVERGENCE: deep id == deeper-producer id" <|
            \() ->
                -- useIt (add3 10): L2 writes p|add3|2 at /a0/r.
                -- useOne ((add3 10) 1): the producer head-inject writes
                -- p|add3|2 at /a0. Same integer id = one identity.
                case runWith True fixture of
                    Err e ->
                        Expect.fail e

                    Ok g ->
                        case ( singletonIds (a0rAnnos "useIt" g), singletonIds (a0Annos "useOne" g) ) of
                            ( deepId :: _, prodId :: _ ) ->
                                if deepId == prodId then
                                    Expect.pass

                                else
                                    Expect.fail
                                        ("deep id "
                                            ++ String.fromInt deepId
                                            ++ " /= producer id "
                                            ++ String.fromInt prodId
                                        )

                            ( ds, ps ) ->
                                Expect.fail
                                    ("expected singletons both ends, got deep="
                                        ++ String.fromInt (List.length ds)
                                        ++ " prod="
                                        ++ String.fromInt (List.length ps)
                                    )
        , Test.test "3. L3 DIFFERENTIAL: accessor arg head gains a|name singleton" <|
            \() ->
                case ( runWith False fixture, runWith True fixture ) of
                    ( Ok offG, Ok onG ) ->
                        case ( a0Annos "useF" offG, a0Annos "useF" onG ) of
                            ( [], _ ) ->
                                Expect.fail "no /a0 for useF — fixture broken"

                            ( offA, onA ) ->
                                if not (List.all isVar offA) then
                                    Expect.fail ("off-arm accessor /a0 expected LVar, got " ++ describe offA)

                                else if List.all isSingleton onA then
                                    Expect.pass

                                else
                                    Expect.fail ("on-arm accessor /a0 expected SINGLETON, got " ++ describe onA)

                    ( Err e, _ ) ->
                        Expect.fail e

                    ( _, Err e ) ->
                        Expect.fail e
        , Test.test "4. LSS_013 BOUNDARY: arity-1 def's beyond-arity arrow arm-identical" <|
            \() ->
                -- mk x = add2 x (declaredArity 1 on a 2-arrow type): neither
                -- L1 nor L2 may claim the second arrow.
                case ( runWith False fixture, runWith True fixture ) of
                    ( Ok offG, Ok onG ) ->
                        let
                            offR =
                                List.map annoSize (a0rAnnos "useMk" offG)

                            onR =
                                List.map annoSize (a0rAnnos "useMk" onG)
                        in
                        if offR == onR then
                            Expect.pass

                        else
                            Expect.fail
                                ("beyond-arity /a0/r moved: "
                                    ++ String.join "," (List.map String.fromInt offR)
                                    ++ " -> "
                                    ++ String.join "," (List.map String.fromInt onR)
                                )

                    ( Err e, _ ) ->
                        Expect.fail e

                    ( _, Err e ) ->
                        Expect.fail e
        , Test.test "5. HEADS UNCHANGED: /a0 of useIt arm-identical (deep walk adds, never disturbs)" <|
            \() ->
                case ( runWith False fixture, runWith True fixture ) of
                    ( Ok offG, Ok onG ) ->
                        let
                            offH =
                                List.map annoSize (a0Annos "useIt" offG)

                            onH =
                                List.map annoSize (a0Annos "useIt" onG)
                        in
                        if offH == onH && List.all (\n -> n >= 1) onH then
                            Expect.pass

                        else
                            Expect.fail
                                ("useIt /a0 moved: "
                                    ++ String.join "," (List.map String.fromInt offH)
                                    ++ " -> "
                                    ++ String.join "," (List.map String.fromInt onH)
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


int2 : Src.Type
int2 =
    tLambda hInt (tLambda hInt hInt)


int3 : Src.Type
int3 =
    tLambda hInt int2


rec : Src.Type
rec =
    tRecord [ ( "name", hInt ) ]


fixture : Src.Module
fixture =
    makeModuleWithTypedDefs "Test"
        [ { name = "add3"
          , args = [ pVar "a", pVar "b", pVar "c" ]
          , tipe = int3
          , body = binopsExpr [ ( varExpr "a", "+" ), ( varExpr "b", "+" ) ] (varExpr "c")
          }
        , { name = "add2"
          , args = [ pVar "a", pVar "b" ]
          , tipe = int2
          , body = binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")
          }
        , { name = "useIt"
          , args = [ pVar "g", pVar "n" ]
          , tipe = tLambda int2 (tLambda hInt hInt)
          , body = callExpr (varExpr "g") [ varExpr "n", varExpr "n" ]
          }
        , { name = "useOne"
          , args = [ pVar "g", pVar "n" ]
          , tipe = tLambda (tLambda hInt hInt) (tLambda hInt hInt)
          , body = callExpr (varExpr "g") [ varExpr "n" ]
          }
        , { name = "useF"
          , args = [ pVar "f", pVar "r" ]
          , tipe = tLambda (tLambda rec hInt) (tLambda rec hInt)
          , body = callExpr (varExpr "f") [ varExpr "r" ]
          }
        , { name = "mk"
          , args = [ pVar "x" ]
          , tipe = int2
          , body = callExpr (varExpr "add2") [ varExpr "x" ]
          }
        , { name = "useMk"
          , args = [ pVar "f", pVar "n" ]
          , tipe = tLambda int2 (tLambda hInt hInt)
          , body = callExpr (varExpr "f") [ varExpr "n", varExpr "n" ]
          }
        , { name = "testValue"
          , args = []
          , tipe = hInt
          , body =
                binopsExpr
                    [ ( callExpr (varExpr "useIt") [ callExpr (varExpr "add3") [ intExpr 10 ], intExpr 1 ], "+" )
                    , ( callExpr (varExpr "useOne") [ callExpr (callExpr (varExpr "add3") [ intExpr 10 ]) [ intExpr 1 ], intExpr 2 ], "+" )
                    , ( callExpr (varExpr "useMk") [ varExpr "mk", intExpr 3 ], "+" )
                    ]
                    (callExpr (varExpr "useF") [ accessorExpr "name", callExpr (varExpr "mkRec") [] ])
          }
        , { name = "mkRec"
          , args = []
          , tipe = rec
          , body = callExpr (varExpr "mkRecHelp") [ intExpr 5 ]
          }
        , { name = "mkRecHelp"
          , args = [ pVar "n" ]
          , tipe = tLambda hInt rec
          , body = Compiler.AST.SourceBuilder.recordExpr [ ( "name", varExpr "n" ) ]
          }
        ]



-- ====== HARNESS ======


runWith : Bool -> Src.Module -> Result String Mono.MonoGraph
runWith injTotal srcModule =
    let
        defaults =
            Config.defaultLss
    in
    Pipeline.runSolverMonoWithLimits Config.defaultLimits
        -- varSucc/varCtorRows pinned OFF (2026-08-31): they write the very
        -- /a0/r position this differential's off-arm asserts as LVar — the
        -- overlapping-flag pin rule.
        { defaults | enabled = True, keyed = True, injTotal = injTotal, varSucc = False, varCtorRows = False }
        srcModule



-- ====== READERS ======


demandsOf : String -> Mono.MonoGraph -> List Mono.MonoType
demandsOf target (Mono.MonoGraph g) =
    Array.foldl
        (\entry acc ->
            case entry of
                Just ( Mono.Global _ name, monoType ) ->
                    if name == target then
                        monoType :: acc

                    else
                        acc

                _ ->
                    acc
        )
        []
        g.registry.reverseMapping


a0Annos : String -> Mono.MonoGraph -> List Mono.LambdaSetAnno
a0Annos target graph =
    List.filterMap
        (\t ->
            case t of
                Mono.MFunction _ _ ((Mono.MFunction _ anno _ _) :: _) _ ->
                    Just anno

                _ ->
                    Nothing
        )
        (demandsOf target graph)


a0rAnnos : String -> Mono.MonoGraph -> List Mono.LambdaSetAnno
a0rAnnos target graph =
    List.filterMap
        (\t ->
            case t of
                Mono.MFunction _ _ ((Mono.MFunction _ _ _ (Mono.MFunction _ rAnno _ _)) :: _) _ ->
                    Just rAnno

                _ ->
                    Nothing
        )
        (demandsOf target graph)


singletonIds : List Mono.LambdaSetAnno -> List Int
singletonIds =
    List.filterMap
        (\a ->
            case a of
                Mono.LSet [ m ] ->
                    Just m

                _ ->
                    Nothing
        )


isVar : Mono.LambdaSetAnno -> Bool
isVar a =
    case a of
        Mono.LVar _ ->
            True

        _ ->
            False


isSingleton : Mono.LambdaSetAnno -> Bool
isSingleton a =
    case a of
        Mono.LSet [ _ ] ->
            True

        _ ->
            False


annoSize : Mono.LambdaSetAnno -> Int
annoSize a =
    case a of
        Mono.LSet ms ->
            List.length ms

        Mono.LVar _ ->
            -1

        Mono.LTop _ ->
            -2

        Mono.LPartial _ ->
            -3


describe : List Mono.LambdaSetAnno -> String
describe annos =
    "["
        ++ String.join ", "
            (List.map
                (\a ->
                    case a of
                        Mono.LTop _ ->
                            "LTop"

                        Mono.LVar n ->
                            "LVar " ++ String.fromInt n

                        Mono.LSet ms ->
                            "LSet " ++ String.fromInt (List.length ms)

                        Mono.LPartial ms ->
                            "LPartial " ++ String.fromInt (List.length ms)
                )
                annos
            )
        ++ "]"
