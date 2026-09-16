module TestLogic.Monomorphize.LssRowDeferTest exposing (suite)

{-| F3-a — ROW-DEFERRED DESTRUCTURE SETS (`lss.flow.rowDefer`,
`plans/lss-container-payload-transport.md` §12.9.5).

`type PS x = Mk Int (Int -> x) | Nope` — the payload arrow is a constructor
FIELD, not a type argument, so the scrutinee's type `PS x` has no slot for
it: destructuring `f` out of `Mk r f` binds ⊤ (`clsDestr`), the destrAnno
projection cannot help (nothing to project), and every consumer fed `f`
reads ⊤. The self-compile's 1,198 `Parse.Primitives` re-wraps are this
shape.

The fix binds `f` to `LRow [row(Mk, payload 1)] []` — a reference to the
constructor's row — carried through the store and resolved post-drain by
`Monomorphize.settleRowRefs` from the COMPLETE union of every `Mk`
construction (`inc` and `dec` here). Pins: the HOF fed `f` reads the 2-set
flag-on and ⊤ flag-off, and no unresolved `LRow` survives in the registry.

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
    Test.describe "F3-a row-deferred destructure sets"
        [ Test.test "1. FLAG-OFF: the HOF fed the destructured payload arrow reads ⊤" <|
            \() ->
                case runWith False fixture of
                    Err e ->
                        Expect.fail e

                    Ok g ->
                        let
                            heads =
                                calleeHeads "apply" g
                        in
                        if List.isEmpty heads then
                            Expect.fail "fixture broken: no apply spec"

                        else if List.all isTop heads then
                            Expect.pass

                        else
                            Expect.fail ("expected ⊤ at apply's callback flag-off, got " ++ String.join ", " (List.map describeAnno heads))
        , Test.test "2. FLAG-ON: the HOF reads the COMPLETE union of the constructor's row (both members)" <|
            \() ->
                case runWith True fixture of
                    Err e ->
                        Expect.fail e

                    Ok g ->
                        let
                            heads =
                                calleeHeads "apply" g
                        in
                        if List.isEmpty heads then
                            Expect.fail "fixture broken: no apply spec"

                        else if List.all isTwoSet heads then
                            Expect.pass

                        else
                            Expect.fail ("expected a 2-member set at apply's callback flag-on, got " ++ String.join ", " (List.map describeAnno heads))
        , Test.test "3. FLAG-ON: no unresolved row reference survives in the registry" <|
            \() ->
                case runWith True fixture of
                    Err e ->
                        Expect.fail e

                    Ok (Mono.MonoGraph g) ->
                        let
                            cov =
                                Array.foldl
                                    (\entry acc ->
                                        case entry of
                                            Just ( _, t ) ->
                                                Mono.annoCoverage t acc

                                            Nothing ->
                                                acc
                                    )
                                    Mono.emptyAnnoCoverage
                                    g.registry.reverseMapping
                        in
                        Expect.equal 0 cov.row
        , Test.test "4. FLAG-ON: the re-wrapping construction's payload is a set, not ⊤" <|
            \() ->
                case runWith True fixture of
                    Err e ->
                        Expect.fail e

                    Ok g ->
                        let
                            annos =
                                ctorPayloadHeads "Mk" g
                        in
                        if List.isEmpty annos then
                            Expect.fail "fixture broken: no Mk spec"

                        else if List.any isTop annos then
                            Expect.fail ("expected no ⊤ at Mk's payload flag-on, got " ++ String.join ", " (List.map describeAnno annos))

                        else
                            Expect.pass
        ]



-- ====== FIXTURE ======


hInt : Src.Type
hInt =
    tLambda (tType "Int" []) (tType "Int" [])


psOfInt : Src.Type
psOfInt =
    tType "PS" [ tType "Int" [] ]


fixture : Src.Module
fixture =
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ { name = "inc", args = [ pVar "x" ], tipe = hInt, body = binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1) }
        , { name = "dec", args = [ pVar "x" ], tipe = hInt, body = binopsExpr [ ( varExpr "x", "-" ) ] (intExpr 1) }
        , { name = "apply", args = [ pVar "f", pVar "n" ], tipe = tLambda hInt hInt, body = callExpr (varExpr "f") [ varExpr "n" ] }
        , { name = "mkA", args = [], tipe = psOfInt, body = callExpr (ctorExpr "Mk") [ intExpr 3, varExpr "inc" ] }
        , { name = "mkB", args = [], tipe = psOfInt, body = callExpr (ctorExpr "Mk") [ intExpr 4, varExpr "dec" ] }
        , -- destructure → HOF argument: the E13 → E1 chain
          { name = "useBox"
          , args = [ pVar "b" ]
          , tipe = tLambda psOfInt (tType "Int" [])
          , body =
                caseExpr (varExpr "b")
                    [ ( pCtor "Mk" [ pVar "r", pVar "f" ], callExpr (varExpr "apply") [ varExpr "f", varExpr "r" ] )
                    , ( pCtor "Nope" [], intExpr 0 )
                    ]
          }
        , -- the re-wrap: destructure and reconstruct (the Parse.Primitives shape)
          { name = "rebox"
          , args = [ pVar "b" ]
          , tipe = tLambda psOfInt psOfInt
          , body =
                caseExpr (varExpr "b")
                    [ ( pCtor "Mk" [ pVar "r", pVar "f" ], callExpr (ctorExpr "Mk") [ varExpr "r", varExpr "f" ] )
                    , ( pCtor "Nope" [], varExpr "b" )
                    ]
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body =
                binopsExpr [ ( callExpr (varExpr "useBox") [ callExpr (varExpr "rebox") [ varExpr "mkA" ] ], "+" ) ]
                    (callExpr (varExpr "useBox") [ callExpr (varExpr "rebox") [ varExpr "mkB" ] ])
          }
        ]
        [ { name = "PS"
          , args = [ "x" ]
          , ctors =
                [ { name = "Mk", args = [ tType "Int" [], tLambda (tType "Int" []) (tVar "x") ] }
                , { name = "Nope", args = [] }
                ]
          }
        ]
        []



-- ====== HARNESS ======


runWith : Bool -> Src.Module -> Result String Mono.MonoGraph
runWith on srcModule =
    let
        defaults =
            Config.defaultLss

        fl =
            Config.defaultLss.flow
    in
    Pipeline.runSolverMonoWithLimits Config.defaultLimits
        { defaults | enabled = True, keyed = True, flow = { fl | rowDefer = on } }
        srcModule



-- ====== READERS ======


calleeHeads : String -> Mono.MonoGraph -> List Mono.LambdaSetAnno
calleeHeads target (Mono.MonoGraph g) =
    Array.foldl
        (\entry acc ->
            case entry of
                Just ( Mono.Global _ name, Mono.MFunction _ _ (p0 :: _) _ ) ->
                    if name == target then
                        Mono.headAnno p0 :: acc

                    else
                        acc

                _ ->
                    acc
        )
        []
        g.registry.reverseMapping


{-| Every arrow annotation inside the named constructor's registry types
(its payloads are its function type's parameters).
-}
ctorPayloadHeads : String -> Mono.MonoGraph -> List Mono.LambdaSetAnno
ctorPayloadHeads target (Mono.MonoGraph g) =
    Array.foldl
        (\entry acc ->
            case entry of
                Just ( Mono.Global _ name, t ) ->
                    if name == target then
                        payloadArrows t ++ acc

                    else
                        acc

                _ ->
                    acc
        )
        []
        g.registry.reverseMapping


{-| The annotations of arrows that sit in PARAMETER position of a (curried)
function type — the constructor's payloads, not its own spine.
-}
payloadArrows : Mono.MonoType -> List Mono.LambdaSetAnno
payloadArrows t =
    case t of
        Mono.MFunction _ _ args result ->
            List.concatMap arrowsIn args ++ payloadArrows result

        _ ->
            []


arrowsIn : Mono.MonoType -> List Mono.LambdaSetAnno
arrowsIn t =
    case t of
        Mono.MFunction _ anno args result ->
            anno :: List.concatMap arrowsIn args ++ arrowsIn result

        Mono.MTuple _ ts ->
            List.concatMap arrowsIn ts

        Mono.MList _ inner ->
            arrowsIn inner

        _ ->
            []


isTop : Mono.LambdaSetAnno -> Bool
isTop anno =
    case anno of
        Mono.LTop _ ->
            True

        _ ->
            False


isTwoSet : Mono.LambdaSetAnno -> Bool
isTwoSet anno =
    case anno of
        Mono.LSet [ _, _ ] ->
            True

        _ ->
            False


describeAnno : Mono.LambdaSetAnno -> String
describeAnno anno =
    case anno of
        Mono.LSet ms ->
            "LSet[" ++ String.join "," (List.map String.fromInt ms) ++ "]"

        Mono.LVar v ->
            "LVar" ++ String.fromInt v

        Mono.LTop k ->
            "LTop" ++ String.fromInt k

        Mono.LPartial ms ->
            "LPartial[" ++ String.join "," (List.map String.fromInt ms) ++ "]"

        Mono.LRow rows ms ->
            "LRow[" ++ String.join "," (List.map String.fromInt rows) ++ "|" ++ String.join "," (List.map String.fromInt ms) ++ "]"
