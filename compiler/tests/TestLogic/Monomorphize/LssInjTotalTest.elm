module TestLogic.Monomorphize.LssInjTotalTest exposing (suite)

{-| INJECTION-TOTALITY COMPLETION — `lss.injTotal`
(plans/lss-coverage-four-levers.md).

Three levers under one flag: L1 completion-join head re-stamp, L2 deep-PAP
successor completion, L3 the Accessor/bare-VarKernel argument arms. L1's
sharpest differentials live at E2E scale (the kernel-ABI ⊤ needs kernel-bodied
defs — see LssGapReturnedClosure/LssGapPapDeepArg flag-on); this suite pins
the fixture-testable levers.

These were off-vs-on DIFFERENTIALS whose off arm additionally pinned
`varSucc`/`varCtorRows` off — those settle passes write the very `/a0/r`
position the off arm asserted as `LVar`. The settle flags were fixed at their
defaults and removed 2026-09-18, so the off arm is no longer constructible.
What the deleted arms pinned: without L2/L3 the deep-PAP `/a0/r` and the
accessor argument head both zonked to `LVar`, and the beyond-arity arrow of
an arity-1 def plus `useIt`'s own `/a0` head were arm-identical (the deep
walk ADDS, never disturbs; LSS\_013 stops it at declaredArity).

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
    Test.describe "L2 deep-PAP + L3 accessor arm"
        [ Test.test "1. L2: deep-PAP /a0/r is a SINGLETON" <|
            \() ->
                case runWith fixture of
                    Ok onG ->
                        case a0rAnnos "useIt" onG of
                            [] ->
                                Expect.fail "no /a0/r for useIt — fixture broken"

                            onA ->
                                if List.all isSingleton onA then
                                    Expect.pass

                                else
                                    Expect.fail ("/a0/r expected SINGLETON, got " ++ describe onA)

                    Err e ->
                        Expect.fail e
        , Test.test "2. L2 PRODUCER CONVERGENCE: deep id == deeper-producer id" <|
            \() ->
                -- useIt (add3 10): L2 writes p|add3|2 at /a0/r.
                -- useOne ((add3 10) 1): the producer head-inject writes
                -- p|add3|2 at /a0. Same integer id = one identity.
                case runWith fixture of
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
        , Test.test "3. L3: an accessor argument head carries the a|name singleton" <|
            \() ->
                case runWith fixture of
                    Ok onG ->
                        case a0Annos "useF" onG of
                            [] ->
                                Expect.fail "no /a0 for useF — fixture broken"

                            onA ->
                                if List.all isSingleton onA then
                                    Expect.pass

                                else
                                    Expect.fail ("accessor /a0 expected SINGLETON, got " ++ describe onA)

                    Err e ->
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


runWith : Src.Module -> Result String Mono.MonoGraph
runWith srcModule =
    let
        defaults =
            Config.defaultLss
    in
    Pipeline.runSolverMonoWithLimits Config.defaultLimits
        { defaults | enabled = True }
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
