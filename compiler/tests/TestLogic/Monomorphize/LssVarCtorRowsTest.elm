module TestLogic.Monomorphize.LssVarCtorRowsTest exposing (suite)

{-| CTOR-ROW VAR WRITES — `lss.varCtorRows` (plans/lss-var-chain-roots.md
§3 Phase 2b).

A ctor spec row's var payload may take the sibling-cell union ONLY when the
cell is COMPLETE: zero ⊤ contributors AND zero var contributions from
flex-marked construction specs (the wrap-class hazard — a construction that
transported an unresolved param flex hides a real inhabitant behind its var
row). Destructure-only var rows are benign.

Three suites:

1.  CLEAN differential — a destructure-only phantom spec's var payload
    flips to the constructing sibling's set.
2.  FLEX-GATE differential — adding `wrap f = Mk 1 f` (flex-marked
    construction) keeps the whole cell UNWRITTEN on the on-arm.
3.  `enrichAnnotationsTopOnly` pins — the AR-V1 retrofit: an LVar base
    never flips through the ⊤-heal path; an LTop base still heals.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , callExpr
        , caseExpr
        , ctorExpr
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
    Test.describe "lss.varCtorRows — completeness-gated ctor-row var writes"
        -- FIXTURE FINDING (plans/lss-var-chain-roots.md §5.1): one-module
        -- fixtures cannot manufacture the target var-row class — in-item
        -- unification + default-on producer machinery cover every payload
        -- this fixture can express (mono AND poly variants measured
        -- all-set off-arm; a never-constructed second instantiation is
        -- PRUNED before the registry the tests read). The corpus battery's
        -- `varctor|wrote`/`varctor|skipFlexVar` counters and named cells
        -- are the differential. The unit pins here: additive-only
        -- invariance on covered fixtures, and the AR-V1 retrofit helper.
        [ Test.test "1. no-op on a fully-covered fixture (additive-only pin)" <|
            \() ->
                case ( runWith False fixtureClean, runWith True fixtureClean ) of
                    ( Ok offG, Ok onG ) ->
                        case ( mkPayloadAnnos offG, mkPayloadAnnos onG ) of
                            ( [], _ ) ->
                                Expect.fail "no Mk /a1 payload positions — fixture broken"

                            ( offA, onA ) ->
                                if List.any isVar offA then
                                    Expect.fail
                                        ("fixture manufactured a var row after all — UPGRADE this pin to a real differential: "
                                            ++ describe offA
                                        )

                                else if offA == onA then
                                    Expect.pass

                                else
                                    Expect.fail
                                        ("varCtorRows CHANGED a covered fixture: off "
                                            ++ describe offA
                                            ++ " vs on "
                                            ++ describe onA
                                        )

                    ( Err e, _ ) ->
                        Expect.fail e

                    ( _, Err e ) ->
                        Expect.fail e
        , Test.test "2. flex fixture: arms agree (gate never rewrites what transport already covered)" <|
            \() ->
                case ( runWith False fixtureFlex, runWith True fixtureFlex ) of
                    ( Ok offG, Ok onG ) ->
                        Expect.equal (describe (mkPayloadAnnos offG)) (describe (mkPayloadAnnos onG))

                    ( Err e, _ ) ->
                        Expect.fail e

                    ( _, Err e ) ->
                        Expect.fail e
        , Test.test "3. enrichAnnotationsTopOnly: LVar base never flips, LTop base heals (AR-V1 pin)" <|
            \() ->
                let
                    varSide =
                        Mono.mFunction (Mono.LVar 3) [ Mono.MInt ] Mono.MInt

                    topSide =
                        Mono.mFunction Mono.topPoison [ Mono.MInt ] Mono.MInt

                    setSide =
                        Mono.mFunction (Mono.LSet [ 7 ]) [ Mono.MInt ] Mono.MInt
                in
                Expect.equal
                    [ Mono.headAnno (Mono.enrichAnnotationsTopOnly varSide setSide)
                    , Mono.headAnno (Mono.enrichAnnotationsTopOnly topSide setSide)
                    , Mono.headAnno (Mono.enrichAnnotationsTopOnly setSide varSide)
                    ]
                    [ Mono.LVar 3
                    , Mono.LSet [ 7 ]
                    , Mono.LSet [ 7 ]
                    ]
        ]



-- ====== FIXTURES ======


hInt : Src.Type
hInt =
    tType "Int" []


psOfInt : Src.Type
psOfInt =
    tType "PS" [ hInt ]


psField : Src.Type
psField =
    tLambda hInt (tVar "x")


psUnion : { name : String, args : List String, ctors : List { name : String, args : List Src.Type } }
psUnion =
    { name = "PS"
    , args = [ "x" ]
    , ctors =
        [ { name = "Mk", args = [ hInt, psField ] }
        , { name = "Nope", args = [] }
        ]
    }


{-| CLEAN: one constructing spec (literal lambda payload — a SET row) and
one destructure-only phantom spec (`peek` on a `Nope`-built value — a VAR
row, unmarked). Same (Mk, /a1) cell, zero ⊤, zero flex marks.
-}
fixtureClean : Src.Module
fixtureClean =
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ { name = "mkBox"
          , args = []
          , tipe = psOfInt
          , body =
                callExpr (ctorExpr "Mk")
                    [ intExpr 3
                    , lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1))
                    ]
          }
        , { name = "useBox"
          , args = [ pVar "b" ]
          , tipe = tLambda psOfInt hInt
          , body =
                caseExpr (varExpr "b")
                    [ ( pCtor "Mk" [ pVar "r", pVar "f" ]
                      , binopsExpr [ ( varExpr "r", "+" ) ] (callExpr (varExpr "f") [ intExpr 2 ])
                      )
                    , ( pCtor "Nope" [], intExpr 0 )
                    ]
          }
        , -- the destructure-only spec at a SECOND instantiation (PS String):
          -- Mk String is never constructed anywhere (its only value route is
          -- the payload-free Nope), so its row payload is an honest
          -- never-written flex — var, UNMARKED. Same (Mk, /a1) cell as the
          -- Int spec's SET row.
          { name = "nopeStr"
          , args = []
          , tipe = tType "PS" [ tType "String" [] ]
          , body = ctorExpr "Nope"
          }
        , { name = "peekStr"
          , args = [ pVar "b" ]
          , tipe = tLambda (tType "PS" [ tType "String" [] ]) hInt
          , body =
                caseExpr (varExpr "b")
                    [ ( pCtor "Mk" [ pVar "r", pVar "f" ], varExpr "r" )
                    , ( pCtor "Nope" [], intExpr 0 )
                    ]
          }
        , { name = "testValue"
          , args = []
          , tipe = hInt
          , body =
                binopsExpr [ ( callExpr (varExpr "useBox") [ varExpr "mkBox" ], "+" ) ]
                    (callExpr (varExpr "peekStr") [ varExpr "nopeStr" ])
          }
        ]
        [ psUnion ]
        []


{-| FLEX: same cell plus `wrap f = Mk 1 f` — a construction transporting
its PARAM's flex arrow. The slow path marks wrap's Mk spec; the cell is
contaminated; nothing in it may be written (the caller's lambda `ℓ2` is a
real inhabitant the union cannot see).
-}
fixtureFlex : Src.Module
fixtureFlex =
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ { name = "mkBox"
          , args = []
          , tipe = psOfInt
          , body =
                callExpr (ctorExpr "Mk")
                    [ intExpr 3
                    , lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1))
                    ]
          }
        , -- POLYMORPHIC wrap behind an indirection: wrap2's param head is a
          -- genuine flex when wrap's body constructs (the caller's ℓ2 lands
          -- only on wrap2's OWN param head, argUnifyVar being head-only), so
          -- the construction transports an UNRESOLVED flex — the marked
          -- hazard shape.
          { name = "wrap"
          , args = [ pVar "f" ]
          , tipe = tLambda (tLambda hInt (tVar "x")) (tType "PS" [ tVar "x" ])
          , body = callExpr (ctorExpr "Mk") [ intExpr 1, varExpr "f" ]
          }
        , { name = "wrap2"
          , args = [ pVar "h" ]
          , tipe = tLambda (tLambda hInt (tVar "y")) (tType "PS" [ tVar "y" ])
          , body = callExpr (varExpr "wrap") [ varExpr "h" ]
          }
        , { name = "useBox"
          , args = [ pVar "b" ]
          , tipe = tLambda psOfInt hInt
          , body =
                caseExpr (varExpr "b")
                    [ ( pCtor "Mk" [ pVar "r", pVar "f" ]
                      , binopsExpr [ ( varExpr "r", "+" ) ] (callExpr (varExpr "f") [ intExpr 2 ])
                      )
                    , ( pCtor "Nope" [], intExpr 0 )
                    ]
          }
        , { name = "testValue"
          , args = []
          , tipe = hInt
          , body =
                binopsExpr
                    [ ( callExpr (varExpr "useBox") [ varExpr "mkBox" ], "+" ) ]
                    (callExpr (varExpr "useBox")
                        [ callExpr (varExpr "wrap2")
                            [ lambdaExpr [ pVar "z" ] (binopsExpr [ ( varExpr "z", "+" ) ] (intExpr 9)) ]
                        ]
                    )
          }
        ]
        [ psUnion ]
        []



-- ====== HARNESS ======


runWith : Bool -> Src.Module -> Result String Mono.MonoGraph
runWith varCtorRows srcModule =
    let
        defaults =
            Config.defaultLss
    in
    Pipeline.runSolverMonoWithLimits Config.defaultLimits
        -- destrAnno pinned ON explicitly: it owns the settle ORDER this
        -- flag interlocks with (var writes before the ⊤-heal).
        { defaults | enabled = True, keyed = True, destrAnno = True, varCtorRows = varCtorRows }
        srcModule



-- ====== READERS ======


{-| Every Mk registry row's payload-arrow head anno (`/a1` of the curried
ctor: `Mk : Int -> (Int -> x) -> PS x`).
-}
mkPayloadAnnos : Mono.MonoGraph -> List Mono.LambdaSetAnno
mkPayloadAnnos (Mono.MonoGraph g) =
    Array.foldl
        (\entry acc ->
            case entry of
                Just ( Mono.Global _ name, monoType ) ->
                    if name == "Mk" then
                        case monoType of
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
