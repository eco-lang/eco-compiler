module TestLogic.Monomorphize.LssRefPapSpineTest exposing (suite)

{-| REFERENCE-SPINE PAP SUCCESSORS — `lss.refPapSpine`
(plans/lss-ref-pap-spine.md).

A standalone reference's injection is head-only, so a multi-arg global passed
as a function argument leaves the callee's `/a0/r` arrow (the value after ONE
application) unwritten — it zonks to `LVar`, the largest surviving var
population (58 % of all var, census 2026-08-28). Under the flag the reference
also writes the PAP successors `p|<g>|<d>` down the loaded spine — the same
ids `injectPapMember` (producer partial applications) mints, so the paths
converge on one identity.

These pins were off-vs-on DIFFERENTIALS, and their off arm additionally
pinned `varSucc`/`varCtorRows` off — those settle passes write the very
`/a0/r` position the off arm asserted as `LVar`. The settle flags were fixed
at their defaults and removed 2026-09-18, so the off arm is no longer
constructible. What the deleted arms pinned: with the successor walk off,
`/a0/r` zonked to `LVar`; the beyond-arity arrow of an arity-1 def and the
`/a0` head itself were arm-identical (the walk ADDS, never disturbs, and
LSS\_013 stops it at declaredArity). What remains asserts the shipping
result at the same positions.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , callExpr
        , intExpr
        , makeModuleWithTypedDefs
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
    Test.describe "PAP successors on reference spines"
        [ Test.test "1. /a0/r of a referenced multi-arg global is a SINGLETON" <|
            \() ->
                case runWith fixture of
                    Ok onG ->
                        case a0rAnnos "useIt" onG of
                            [] ->
                                Expect.fail "no /a0/r position for `useIt` — fixture broken"

                            onAnnos ->
                                if List.all isSingleton onAnnos then
                                    Expect.pass

                                else
                                    Expect.fail ("/a0/r expected SINGLETON, got " ++ describe onAnnos)

                    Err e ->
                        Expect.fail e
        , Test.test "2. PRODUCER CONVERGENCE: reference-spine id == partial-application id" <|
            \() ->
                -- `useIt plus2` puts p|plus2|1 at useIt's /a0/r via the NEW
                -- path; `useIt2 (plus2 1)` puts p|plus2|1 at useIt2's /a0 via
                -- papMembers' PRODUCER path. Same integer id = one identity.
                case runWith fixture of
                    Err e ->
                        Expect.fail e

                    Ok g ->
                        case ( singletonIds (a0rAnnos "useIt" g), singletonIds (a0Annos "useIt2" g) ) of
                            ( spineId :: _, prodId :: _ ) ->
                                if spineId == prodId then
                                    Expect.pass

                                else
                                    Expect.fail
                                        ("spine id "
                                            ++ String.fromInt spineId
                                            ++ " /= producer id "
                                            ++ String.fromInt prodId
                                            ++ " — the two p| mints diverged"
                                        )

                            ( sp, pr ) ->
                                Expect.fail
                                    ("expected singletons at both ends, got spine="
                                        ++ String.fromInt (List.length sp)
                                        ++ " producer="
                                        ++ String.fromInt (List.length pr)
                                    )
        , Test.test "3. NO MULTI-SETS: /a0/r is a strict singleton" <|
            \() ->
                case runWith fixture of
                    Err e ->
                        Expect.fail e

                    Ok g ->
                        case a0rAnnos "useIt" g of
                            [] ->
                                Expect.fail "no /a0/r position flag-on"

                            annos ->
                                if List.all isSingleton annos then
                                    Expect.pass

                                else
                                    Expect.fail ("expected singletons, got " ++ describe annos)
        ]



-- ====== FIXTURE ======


hInt : Src.Type
hInt =
    tType "Int" []


int2 : Src.Type
int2 =
    -- Int -> Int -> Int
    tLambda hInt (tLambda hInt hInt)


fixture : Src.Module
fixture =
    makeModuleWithTypedDefs "Test"
        [ { name = "plus2"
          , args = [ pVar "a", pVar "b" ]
          , tipe = int2
          , body = binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")
          }
        , { name = "useIt"
          , args = [ pVar "f", pVar "n" ]
          , tipe = tLambda int2 (tLambda hInt hInt)
          , body = callExpr (varExpr "f") [ varExpr "n", varExpr "n" ]
          }
        , { name = "useIt2"
          , args = [ pVar "g", pVar "n" ]
          , tipe = tLambda (tLambda hInt hInt) (tLambda hInt hInt)
          , body = callExpr (varExpr "g") [ varExpr "n" ]
          }
        , { name = "mk"
          , args = [ pVar "x" ]

          -- declaredArity 1, 2-arrow type: `mk x = plus2 x` (eta-reduced
          -- partial application) — the second arrow is the BODY's value.
          , tipe = int2
          , body = callExpr (varExpr "plus2") [ varExpr "x" ]
          }
        , { name = "useIt3"
          , args = [ pVar "f", pVar "n" ]
          , tipe = tLambda int2 (tLambda hInt hInt)
          , body = callExpr (varExpr "f") [ varExpr "n", varExpr "n" ]
          }
        , { name = "testValue"
          , args = []
          , tipe = hInt
          , body =
                binopsExpr
                    [ ( callExpr (varExpr "useIt") [ varExpr "plus2", intExpr 1 ], "+" )
                    , ( callExpr (varExpr "useIt2") [ callExpr (varExpr "plus2") [ intExpr 1 ], intExpr 2 ], "+" )
                    ]
                    (callExpr (varExpr "useIt3") [ varExpr "mk", intExpr 3 ])
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


{-| The first argument's own head annotation (/a0).
-}
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


{-| The first argument's RESULT arrow annotation (/a0/r) — the value after
applying the argument once.
-}
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
