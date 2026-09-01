module TestLogic.Monomorphize.LssDestrAnnoTest exposing (suite)

{-| DESTRUCTOR ANNOTATIONS — `lss.destrAnno`
(plans/lss-ctor-arrow-identity.md §9.5/§9.6).

`specializeDestructor` classifies the bound variable's type STORELESSLY — ⊤
at every arrow by construction — and that stamp is the manufacturer of 82 %
of the residual decl-⊤ (§9.3) plus, via varEnv propagation, 1,012 registry
positions. The flag repairs it two ways at the one site: FIX A merges the
projection's type-argument-borne annotations (the paper's TIU substitution);
FIX B merges the set-biased union of the ctor global's spec demands (the
paper's global-store solution reassembled — union can only widen, AR-D2).

Fixture: `Box (Int -> Int)` constructed with a lambda, destructured, and the
payload applied — the unbox class (channel A) that the P0 measured at
`destranno top|k1`. The suite is an off-vs-on DIFFERENTIAL plus the
`enrichAnnotations` purity pins re-landed from the argFeedback arc.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , callExpr
        , ctorExpr
        , caseExpr
        , intExpr
        , lambdaExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pCtor
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
    Test.describe "lss.destrAnno — destructor-bound annotations"
        [ Test.test "1. DIFFERENTIAL: the destructured payload arrow flips ⊤ -> SET" <|
            \() ->
                case ( runWith False fixture, runWith True fixture ) of
                    ( Ok offG, Ok onG ) ->
                        case ( unboxArgAnnos offG, unboxArgAnnos onG ) of
                            ( [], _ ) ->
                                Expect.fail "no Box /a0 position — fixture broken"

                            ( offA, onA ) ->
                                if not (List.any isTop offA) then
                                    Expect.fail ("off-arm expected a ⊤ somewhere, got " ++ describe offA)

                                else if List.any isSet onA && not (List.any isTop onA) then
                                    Expect.pass

                                else
                                    Expect.fail ("on-arm expected SETs and no ⊤, got " ++ describe onA)

                    ( Err e, _ ) ->
                        Expect.fail e

                    ( _, Err e ) ->
                        Expect.fail e
        , Test.test "2. enrichAnnotations never downgrades a set (re-landed pin)" <|
            \() ->
                let
                    setSide =
                        Mono.mFunction (Mono.LSet [ 7 ]) [ Mono.MInt ] Mono.MInt

                    varSide =
                        Mono.mFunction (Mono.LVar 3) [ Mono.MInt ] Mono.MInt

                    topSide =
                        Mono.mFunction Mono.topPoison [ Mono.MInt ] Mono.MInt

                    twoSide =
                        Mono.mFunction (Mono.LSet [ 9 ]) [ Mono.MInt ] Mono.MInt
                in
                Expect.equal
                    [ Mono.headAnno (Mono.enrichAnnotations setSide varSide)
                    , Mono.headAnno (Mono.enrichAnnotations setSide topSide)
                    , Mono.headAnno (Mono.enrichAnnotations varSide setSide)
                    , Mono.headAnno (Mono.enrichAnnotations topSide setSide)
                    , Mono.headAnno (Mono.enrichAnnotations setSide twoSide)
                    ]
                    [ Mono.LSet [ 7 ]
                    , Mono.LSet [ 7 ]
                    , Mono.LSet [ 7 ]
                    , Mono.LSet [ 7 ]
                    , Mono.LSet [ 7, 9 ]
                    ]
        , Test.test "3. structure is untouched on shape mismatch (MONO_029 pin)" <|
            \() ->
                let
                    structural =
                        Mono.mFunction Mono.topAbi [ Mono.MInt, Mono.MInt ] Mono.MInt

                    mismatched =
                        Mono.mFunction (Mono.LSet [ 5 ]) [ Mono.MInt ] Mono.MInt
                in
                Expect.equal structural (Mono.enrichAnnotations structural mismatched)
        ]



-- ====== FIXTURE ======


hInt : Src.Type
hInt =
    tType "Int" []


int1 : Src.Type
int1 =
    tLambda hInt hInt


boxOfFn : Src.Type
boxOfFn =
    tType "PS" [ hInt ]


psFieldFn : Src.Type
psFieldFn =
    tLambda hInt (tVar "x")


fixture : Src.Module
fixture =
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ { name = "mkBox"
          , args = []
          , tipe = boxOfFn
          , body = callExpr (ctorExpr "Mk") [ intExpr 3, lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1)) ]
          }
        , -- The destructure-and-apply: the binding of `f` is the §9.3 site;
          -- without the flag its arrow is ⊤ (a MULTI-ctor union with a
          -- phantom var — the probe's exact PStep shape; a single-ctor
          -- monomorphic Box canonicalizes into an already-var path and
          -- reproduces nothing, the first fixture's mistake).
          { name = "useBox"
          , args = [ pVar "b" ]
          , tipe = tLambda boxOfFn hInt
          , body =
                caseExpr (varExpr "b")
                    [ ( pCtor "Mk" [ pVar "r", pVar "f" ]
                      , binopsExpr [ ( varExpr "r", "+" ) ] (callExpr (varExpr "f") [ intExpr 2 ])
                      )
                    , ( pCtor "Nope" [], intExpr 0 )
                    ]
          }
        , -- The REBUILD (the probe's manufacturing pattern): destructure and
          -- reconstruct. Off-arm, `f` binds ⊤ (storeless classify) and the
          -- rebuilt `Mk r f` writes that ⊤ into Mk's demand — the observed
          -- registry row. On-arm, Fix B recovers `f` from the ctor-demand
          -- union before the rebuild, so no ⊤ is ever written.
          { name = "rebox"
          , args = [ pVar "b" ]
          , tipe = tLambda boxOfFn boxOfFn
          , body =
                caseExpr (varExpr "b")
                    [ ( pCtor "Mk" [ pVar "r", pVar "f" ]
                      , callExpr (ctorExpr "Mk") [ varExpr "r", varExpr "f" ]
                      )
                    , ( pCtor "Nope" [], varExpr "b" )
                    ]
          }
        , { name = "testValue"
          , args = []
          , tipe = hInt
          , body =
                binopsExpr [ ( callExpr (varExpr "useBox") [ varExpr "mkBox" ], "+" ) ]
                    (callExpr (varExpr "useBox") [ callExpr (varExpr "rebox") [ varExpr "mkBox" ] ])
          }
        ]
        [ { name = "PS"
          , args = [ "x" ]
          , ctors =
                [ { name = "Mk", args = [ hInt, psFieldFn ] }
                , { name = "Nope", args = [] }
                ]
          }
        ]
        []



-- ====== HARNESS ======


runWith : Bool -> Src.Module -> Result String Mono.MonoGraph
runWith destrAnno srcModule =
    let
        defaults =
            Config.defaultLss
    in
    Pipeline.runSolverMonoWithLimits Config.defaultLimits
        { defaults | enabled = True, keyed = True, destrAnno = destrAnno }
        srcModule



-- ====== READERS ======


{-| The `Mk` ctor's OWN registry rows at the payload position (`/a1`) —
across ALL its specs. The rebuild spec's demand is where the off-arm ⊤ is
written (the §9.4 propagation multiplier in miniature).
-}
unboxArgAnnos : Mono.MonoGraph -> List Mono.LambdaSetAnno
unboxArgAnnos (Mono.MonoGraph g) =
    Array.foldl
        (\entry acc ->
            case entry of
                Just ( Mono.Global _ name, monoType ) ->
                    if name == "Mk" then
                        case monoType of
                            -- Mk : Int -> (Int -> x) -> PS x, curried: the
                            -- payload arrow is the SECOND arrow's head arg.
                            Mono.MFunction _ _ [ _ ] (Mono.MFunction _ _ [ Mono.MFunction _ anno _ _ ] _) ->
                                anno :: acc

                            _ ->
                                acc

                    else
                        acc

                _ ->
                    acc
        )
        []
        g.registry.reverseMapping


isTop : Mono.LambdaSetAnno -> Bool
isTop =
    Mono.isTopAnno


isSet : Mono.LambdaSetAnno -> Bool
isSet a =
    case a of
        Mono.LSet (_ :: _) ->
            True

        _ ->
            False


describe : List Mono.LambdaSetAnno -> String
describe annos =
    "["
        ++ String.join ", "
            (List.map
                (\a ->
                    case a of
                        Mono.LTop k ->
                            "LTop " ++ Mono.topKindLabel k

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
