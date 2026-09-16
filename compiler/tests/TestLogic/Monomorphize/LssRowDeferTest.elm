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
        , pTuple
        , pVar
        , tLambda
        , tTuple
        , tType
        , tVar
        , tupleExpr
        , varExpr
        )
import Compiler.Eco.Config as Config
import Compiler.Monomorphize.MonoTraverse as Traverse
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
        , Test.test "5. FLAG-ON: no unresolved row reference survives on any AST node either" <|
            \() ->
                -- `settleRowRefs` rewrites the registry AND the node array: a
                -- row left on a destructor or expression type would be sound
                -- (declined like ⊤) but inert, and it is the 13,984 mints —
                -- not the ~671 registry positions — that the fix is for.
                case runWith True fixture of
                    Err e ->
                        Expect.fail e

                    Ok (Mono.MonoGraph g) ->
                        Expect.equal 0
                            (Array.foldl
                                (\maybeNode n ->
                                    case maybeNode of
                                        Just node ->
                                            if Traverse.anyNodeType hasRowAnno node then
                                                n + 1

                                            else
                                                n

                                        Nothing ->
                                            n
                                )
                                0
                                g.nodes
                            )
        , Test.test "6. NESTED PAYLOAD: a function reached THROUGH a tuple inside the payload resolves" <|
            \() ->
                -- The payload projection is not the path's last step here (the
                -- tuple index is), so before the anchor walk this destructure
                -- kept its storeless ⊤ — `rowDefer|notPayload`.
                case ( runWith False nested, runWith True nested ) of
                    ( Ok offG, Ok onG ) ->
                        let
                            off =
                                calleeHeads "apply" offG

                            on =
                                calleeHeads "apply" onG
                        in
                        if List.isEmpty on then
                            Expect.fail "fixture broken: no apply spec"

                        else if not (List.all isTop off) then
                            Expect.fail ("expected ⊤ flag-off, got " ++ String.join ", " (List.map describeAnno off))

                        else if List.all isTwoSet on then
                            Expect.pass

                        else
                            Expect.fail ("expected the 2-member row union flag-on, got " ++ String.join ", " (List.map describeAnno on))

                    ( Err e, _ ) ->
                        Expect.fail e

                    ( _, Err e ) ->
                        Expect.fail e
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



{-| `type PT x = MkT ( Int, Int -> x ) | NoT` — the arrow sits inside a TUPLE
inside the payload, so the destructure's last step is the tuple index.
-}
nested : Src.Module
nested =
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ { name = "inc", args = [ pVar "x" ], tipe = hInt, body = binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1) }
        , { name = "dec", args = [ pVar "x" ], tipe = hInt, body = binopsExpr [ ( varExpr "x", "-" ) ] (intExpr 1) }
        , { name = "apply", args = [ pVar "f", pVar "n" ], tipe = tLambda hInt hInt, body = callExpr (varExpr "f") [ varExpr "n" ] }
        , { name = "mkA", args = [], tipe = ptOfInt, body = callExpr (ctorExpr "MkT") [ tupleExpr (intExpr 3) (varExpr "inc") ] }
        , { name = "mkB", args = [], tipe = ptOfInt, body = callExpr (ctorExpr "MkT") [ tupleExpr (intExpr 4) (varExpr "dec") ] }
        , { name = "useT"
          , args = [ pVar "b" ]
          , tipe = tLambda ptOfInt (tType "Int" [])
          , body =
                caseExpr (varExpr "b")
                    [ ( pCtor "MkT" [ pTuple (pVar "r") (pVar "f") ], callExpr (varExpr "apply") [ varExpr "f", varExpr "r" ] )
                    , ( pCtor "NoT" [], intExpr 0 )
                    ]
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body =
                binopsExpr [ ( callExpr (varExpr "useT") [ varExpr "mkA" ], "+" ) ]
                    (callExpr (varExpr "useT") [ varExpr "mkB" ])
          }
        ]
        [ { name = "PT"
          , args = [ "x" ]
          , ctors =
                [ { name = "MkT", args = [ tTuple (tType "Int" []) (tLambda (tType "Int" []) (tVar "x")) ] }
                , { name = "NoT", args = [] }
                ]
          }
        ]
        []


ptOfInt : Src.Type
ptOfInt =
    tType "PT" [ tType "Int" [] ]



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


hasRowAnno : Mono.MonoType -> Bool
hasRowAnno t =
    case t of
        Mono.MFunction _ anno _ _ ->
            case anno of
                Mono.LRow _ _ ->
                    True

                _ ->
                    False

        _ ->
            False


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
