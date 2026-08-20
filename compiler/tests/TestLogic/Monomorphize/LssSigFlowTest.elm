module TestLogic.Monomorphize.LssSigFlowTest exposing (suite)

{-| LSS_020 — signature set-flow completion (GAP-2,
`plans/lss-fidelity-3-signature-flow-completion.md` §B).

Under `lss.sigFlow` the inference walk connects ground-typed intra-def flow
to signature slots, so def signatures stop being trivial and callers receive
rep links + members. These tests pin the mechanism through OBSERVABLE graph
state — the annotations of the stored (keyed) demand types in the registry:

1.  `chooseHandler b f g = if b then f else g` (ground annotation): the
    result arrow rep-links to BOTH param arrows, so a caller passing two
    distinct lambdas sees an honest 2-member set on the result — flag-off it
    sees nothing (the channel is empty).
2.  `mk2 s = if b then λ else λ`: body lambdas' members transport through
    the signature to the caller's result arrow (member flow, not just rep).
3.  Negative control `apply f x = f x` (polymorphic): no spurious members —
    flag-on demands are IDENTICAL to flag-off (this also pins the B.1.f
    self-id filter: without it every ≥1-param def goes nontrivial with its
    own raw `l|` spine member).
4.  HONESTY pin (§0.4(3) of the plan): `pick b g = if b then inc else g 0`
    mixes an honest branch with an opaque one (a call result). The hub must
    POISON — publishing the partial `{g|inc}` singleton would be the
    false-singleton devirt miscompile. Result arrow must be `LTop`, never a
    singleton.
5.  TailDef pin (§0.4(1)): a self-tail-recursive `countdown n k = if n == 0
    then k else countdown (n - 1) k` — the TailDef body is ARG-STRIPPED, so
    the root join must peel |args| arrows (and bind them); the tail call
    itself is `WpSelf` (contributes nothing to its own hub). Flag-on the
    result arrow carries the caller's `k` member via rep transport; a broken
    peel poisons the signature instead (LTop everywhere).
6.  B.4 widening rider: with `maxSetSize = 1`, the 2-member signature arrow
    of `mk2` widens (`top=True`) and bumps `widenedBySigSize` (asserted via
    the report line — `runSolverMonoWithReport`).

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , binopsExpr
        , boolExpr
        , callExpr
        , ifExpr
        , intExpr
        , lambdaExpr
        , makeModuleWithTypedDefs
        , pVar
        , tLambda
        , tType
        , tVar
        , varExpr
        )
import Compiler.Eco.Config as Config
import Dict
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    Test.describe "LSS_020 signature set-flow (lss.sigFlow)"
        [ Test.test "1a. chooseHandler flag ON: caller's two lambdas meet in an honest 2-set via rep links" <|
            \() ->
                case run True chooseHandlerModule of
                    Err msg ->
                        Expect.fail msg

                    Ok graph ->
                        if List.any (annoHasSize 2) (allAnnos "chooseHandler" graph) then
                            Expect.pass

                        else
                            Expect.fail
                                ("expected a 2-member LSet on some chooseHandler demand arrow, got: "
                                    ++ describeAnnos (allAnnos "chooseHandler" graph)
                                )
        , Test.test "1b. chooseHandler flag OFF: the channel is empty — no multi-member set forms" <|
            \() ->
                case run False chooseHandlerModule of
                    Err msg ->
                        Expect.fail msg

                    Ok graph ->
                        if List.any (annoHasSize 2) (allAnnos "chooseHandler" graph) then
                            Expect.fail "flag-off demand unexpectedly carries a 2-member set"

                        else
                            Expect.pass
        , Test.test "2. mk2 flag ON: body lambdas' members reach the caller's result arrow" <|
            \() ->
                case ( run True mk2Module, run False mk2Module ) of
                    ( Ok on, Ok off ) ->
                        if
                            List.any (annoHasSize 2) (allAnnos "mk2" on)
                                && not (List.any (annoHasSize 2) (allAnnos "mk2" off))
                        then
                            Expect.pass

                        else
                            Expect.fail
                                ("expected a 2-member LSet flag-on only; on="
                                    ++ describeAnnos (allAnnos "mk2" on)
                                    ++ " off="
                                    ++ describeAnnos (allAnnos "mk2" off)
                                )

                    ( Err e, _ ) ->
                        Expect.fail e

                    ( _, Err e ) ->
                        Expect.fail e
        , Test.test "3. negative control: polymorphic `apply` demands are identical flag-on/flag-off" <|
            \() ->
                case ( run True applyModule, run False applyModule ) of
                    ( Ok on, Ok off ) ->
                        Expect.equal
                            (List.map annosOf (demandsOf "apply" off))
                            (List.map annosOf (demandsOf "apply" on))

                    ( Err e, _ ) ->
                        Expect.fail e

                    ( _, Err e ) ->
                        Expect.fail e
        , Test.test "4. HONESTY pin: a hub mixing an honest branch with a call result POISONS (no false singleton)" <|
            \() ->
                case run True pickModule of
                    Err msg ->
                        Expect.fail msg

                    Ok graph ->
                        let
                            resultAnnos =
                                List.filterMap deepestRetAnno (demandsOf "pick" graph)
                        in
                        if List.isEmpty resultAnnos then
                            Expect.fail "no pick demands found"

                        else if List.all (\anno -> anno == Mono.LTop) resultAnnos then
                            Expect.pass

                        else
                            Expect.fail
                                ("expected LTop on every pick result arrow (honesty rule), got: "
                                    ++ describeAnnos resultAnnos
                                )
        , Test.test "5. TailDef pin: tail-recursive countdown transports k to its result arrow flag-on (peel + WpSelf)" <|
            \() ->
                case ( run True countdownModule, run False countdownModule ) of
                    ( Ok on, Ok off ) ->
                        let
                            onRes =
                                List.filterMap deepestRetAnno (demandsOf "countdown" on)

                            offRes =
                                List.filterMap deepestRetAnno (demandsOf "countdown" off)
                        in
                        if List.any (annoHasSize 1) onRes && List.all (\anno -> anno == Mono.LTop) offRes then
                            Expect.pass

                        else
                            Expect.fail
                                ("expected a 1-member LSet on a countdown result arrow flag-on and LTop flag-off; on="
                                    ++ describeAnnos onRes
                                    ++ " off="
                                    ++ describeAnnos offRes
                                )

                    ( Err e, _ ) ->
                        Expect.fail e

                    ( _, Err e ) ->
                        Expect.fail e
        , Test.test "6. B.4 rider: a >maxSetSize signature arrow widens and bumps widenedBySigSize" <|
            \() ->
                let
                    defaults =
                        Config.defaultLss
                in
                case
                    Pipeline.runSolverMonoWithReport Config.defaultLimits
                        { defaults | enabled = True, keyed = True, sigFlow = True, maxSetSize = 1 }
                        mk2Module
                of
                    Err msg ->
                        Expect.fail msg

                    Ok ( graph, maybeReport ) ->
                        let
                            report =
                                Maybe.withDefault "" maybeReport

                            resultAnnos =
                                List.filterMap deepestRetAnno (demandsOf "mk2" graph)
                        in
                        Expect.all
                            [ \() ->
                                if String.contains "bySigSize=1" report then
                                    Expect.pass

                                else
                                    Expect.fail ("expected bySigSize=1 in the report, got: " ++ report)
                            , \() ->
                                if List.all (\anno -> anno == Mono.LTop) resultAnnos && not (List.isEmpty resultAnnos) then
                                    Expect.pass

                                else
                                    Expect.fail
                                        ("expected the widened result arrow to read LTop, got: "
                                            ++ describeAnnos resultAnnos
                                        )
                            ]
                            ()
        ]



-- ====== HARNESS ======


run : Bool -> Src.Module -> Result String Mono.MonoGraph
run sigFlow srcModule =
    let
        defaults =
            Config.defaultLss
    in
    Pipeline.runSolverMonoWithLimits
        Config.defaultLimits
        -- keyed = True (the shipping default) is what stores annotated
        -- demands in the registry in the first place.
        { defaults | enabled = True, keyed = True, sigFlow = sigFlow }
        srcModule


{-| Every stored (keyed) demand type for the named global, from the
registry's reverse mapping (MuTieTest precedent).
-}
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


{-| Every arrow annotation anywhere in a stored demand type (one anno per
`MFunction` node — zonk emits one arrow per node).
-}
annosOf : Mono.MonoType -> List Mono.LambdaSetAnno
annosOf t =
    case t of
        Mono.MFunction _ anno args ret ->
            anno :: (List.concatMap annosOf args ++ annosOf ret)

        Mono.MList _ el ->
            annosOf el

        Mono.MTuple _ els ->
            List.concatMap annosOf els

        Mono.MRecord _ fields ->
            Dict.foldl (\_ ft acc -> acc ++ annosOf ft) [] fields

        Mono.MCustom _ _ _ args ->
            List.concatMap annosOf args

        _ ->
            []


allAnnos : String -> Mono.MonoGraph -> List Mono.LambdaSetAnno
allAnnos target graph =
    List.concatMap annosOf (demandsOf target graph)


{-| The RESULT arrow's annotation: the deepest `MFunction` on the return
spine (its own head anno). `Nothing` for non-function demands.
-}
deepestRetAnno : Mono.MonoType -> Maybe Mono.LambdaSetAnno
deepestRetAnno t =
    case t of
        Mono.MFunction _ anno _ ret ->
            case deepestRetAnno ret of
                Just deeper ->
                    Just deeper

                Nothing ->
                    Just anno

        _ ->
            Nothing


annoHasSize : Int -> Mono.LambdaSetAnno -> Bool
annoHasSize n anno =
    case anno of
        Mono.LSet members ->
            List.length members == n

        Mono.LTop ->
            False


describeAnnos : List Mono.LambdaSetAnno -> String
describeAnnos annos =
    String.join ", "
        (List.map
            (\anno ->
                case anno of
                    Mono.LTop ->
                        "LTop"

                    Mono.LSet ms ->
                        "LSet[" ++ String.join "," (List.map String.fromInt ms) ++ "]"
            )
            annos
        )



-- ====== FIXTURES ======


hInt : Src.Type
hInt =
    tLambda (tType "Int" []) (tType "Int" [])


{-| Test 1: params flow through an If into the result — ground annotation.
-}
chooseHandlerModule : Src.Module
chooseHandlerModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "chooseHandler"
          , args = [ pVar "b", pVar "f", pVar "g" ]
          , tipe = tLambda (tType "Bool" []) (tLambda hInt (tLambda hInt hInt))
          , body = ifExpr (varExpr "b") (varExpr "f") (varExpr "g")
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body =
                callExpr
                    (callExpr (varExpr "chooseHandler")
                        [ boolExpr True
                        , lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1))
                        , lambdaExpr [ pVar "y" ] (binopsExpr [ ( varExpr "y", "+" ) ] (intExpr 2))
                        ]
                    )
                    [ intExpr 9 ]
          }
        ]


{-| Test 2/6: body lambdas meet in the result arrow via the hub.
-}
mk2Module : Src.Module
mk2Module =
    makeModuleWithTypedDefs "Test"
        [ { name = "mk2"
          , args = [ pVar "s" ]
          , tipe = tLambda (tType "Bool" []) hInt
          , body =
                ifExpr (varExpr "s")
                    (lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1)))
                    (lambdaExpr [ pVar "y" ] (binopsExpr [ ( varExpr "y", "+" ) ] (intExpr 2)))
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body = callExpr (callExpr (varExpr "mk2") [ boolExpr True ]) [ intExpr 4 ]
          }
        ]


{-| Test 3: polymorphic negative control — the signature must stay trivial
(self-id filtered; the local-callee join adds nothing at TVar positions).
-}
applyModule : Src.Module
applyModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "apply"
          , args = [ pVar "f", pVar "x" ]
          , tipe = tLambda (tLambda (tVar "a") (tVar "b")) (tLambda (tVar "a") (tVar "b"))
          , body = callExpr (varExpr "f") [ varExpr "x" ]
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body =
                callExpr (varExpr "apply")
                    [ lambdaExpr [ pVar "y" ] (binopsExpr [ ( varExpr "y", "+" ) ] (intExpr 1))
                    , intExpr 3
                    ]
          }
        ]


{-| Test 4: an If mixing an HONEST branch (a standalone global) with an
OPAQUE one (a call result) — the hub must poison, not publish `{g|inc}`.
-}
pickModule : Src.Module
pickModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "inc"
          , args = [ pVar "x" ]
          , tipe = hInt
          , body = binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1)
          }
        , { name = "mkAdd"
          , args = [ pVar "a", pVar "b" ]
          , tipe = tLambda (tType "Int" []) hInt
          , body = binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")
          }
        , { name = "pick"
          , args = [ pVar "c", pVar "g" ]
          , tipe = tLambda (tType "Bool" []) (tLambda (tLambda (tType "Int" []) hInt) hInt)
          , body =
                ifExpr (varExpr "c")
                    (varExpr "inc")
                    (callExpr (varExpr "g") [ intExpr 0 ])
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body =
                callExpr
                    (callExpr (varExpr "pick") [ boolExpr True, varExpr "mkAdd" ])
                    [ intExpr 7 ]
          }
        ]


{-| Test 5: self-tail-recursive, function-returning — the TailDef shape
(arg-stripped body at the result type).
-}
countdownModule : Src.Module
countdownModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "inc"
          , args = [ pVar "x" ]
          , tipe = hInt
          , body = binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1)
          }
        , { name = "countdown"
          , args = [ pVar "n", pVar "k" ]
          , tipe = tLambda (tType "Int" []) (tLambda hInt hInt)
          , body =
                ifExpr (binopsExpr [ ( varExpr "n", "==" ) ] (intExpr 0))
                    (varExpr "k")
                    (callExpr (varExpr "countdown")
                        [ binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1)
                        , varExpr "k"
                        ]
                    )
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body =
                callExpr
                    (callExpr (varExpr "countdown") [ intExpr 3, varExpr "inc" ])
                    [ intExpr 5 ]
          }
        ]
