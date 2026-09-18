module TestLogic.Monomorphize.LssAccessAndLitFactsTest exposing (suite)

{-| E15 (`lss.flow.accessFlow`) and F4-sig (`lss.flow.litFacts`) —
plans/lss-container-payload-transport.md §12.10.1. The F4 probe's shapes,
turned into pins. Every test is a DIFFERENTIAL (flag-off pins the defect).

1.  E15 argument: `apply r.f 2` — the field's set reaches the HOF.
2.  E15 callee: `r.f 2` — the access node (the callee) carries the field's
    set instead of the storeless `clsMisc` ⊤.
3.  F4-sig: a def RETURNING a record of functions carries a fact at the
    field arrow, so its caller's consumer reads the set (the probe measured
    `LPartial` in the registry and `LVar` at the consumer).
4.  F4-lit-list: a ground-typed list literal of two functions reaches its
    consumer as the 2-set (through a let, F3-b on), not as `clsMisc` ⊤.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( accessExpr
        , binopsExpr
        , callExpr
        , define
        , intExpr
        , letExpr
        , listExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pVar
        , recordExpr
        , strExpr
        , tLambda
        , tRecord
        , tType
        , varExpr
        )
import Compiler.Eco.Config as Config
import Compiler.Monomorphize.MonoTraverse as Traverse
import Dict
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


type alias Flags =
    { letOverlay : Bool, accessFlow : Bool, litFacts : Bool }


suite : Test
suite =
    Test.describe "E15 access flow + F4-sig literal facts"
        [ Test.test "1a. E15 ARG, flag-off: `apply r.f 2` hands the HOF no set" <|
            \() -> expectHeads { letOverlay = True, accessFlow = False, litFacts = False } argShape (calleeHeads "apply") (not << isSet) "no set"
        , Test.test "1b. E15 ARG, flag-on: the HOF reads the field's singleton" <|
            \() -> expectHeads { letOverlay = True, accessFlow = True, litFacts = False } argShape (calleeHeads "apply") isSingleton "a singleton"
        , Test.test "2a. E15 CALLEE, flag-off: the access-node callee is ⊤" <|
            \() -> expectHeads { letOverlay = True, accessFlow = False, litFacts = False } calleeShape accessCalleeHeads isTop "⊤"
        , Test.test "2b. E15 CALLEE, flag-on: the access-node callee carries the field's singleton" <|
            \() -> expectHeads { letOverlay = True, accessFlow = True, litFacts = False } calleeShape accessCalleeHeads isSingleton "a singleton"
        , Test.test "3a. F4-sig, flag-off: a returned record's field arrow reaches the consumer as var" <|
            \() -> expectHeads { letOverlay = False, accessFlow = False, litFacts = False } returnedShape (fieldHeads "useRec" "f") isVar "var"
        , Test.test "3b. F4-sig, flag-on: the consumer reads the singleton" <|
            \() -> expectHeads { letOverlay = False, accessFlow = False, litFacts = True } returnedShape (fieldHeads "useRec" "f") isSingleton "a singleton"
        , Test.test "4a. F4-lit-list, flag-off: a ground list literal of functions reaches its consumer as ⊤" <|
            \() -> expectHeads { letOverlay = True, accessFlow = False, litFacts = False } listShape (listElemHeads "useL") isTop "⊤"
        , Test.test "4b. F4-lit-list, flag-on: the consumer reads the 2-set" <|
            \() -> expectHeads { letOverlay = True, accessFlow = True, litFacts = False } listShape (listElemHeads "useL") isTwoSet "a 2-set"
        ]


expectHeads : Flags -> Src.Module -> (Mono.MonoGraph -> List Mono.LambdaSetAnno) -> (Mono.LambdaSetAnno -> Bool) -> String -> Expect.Expectation
expectHeads flags fixture reader ok what =
    case runWith flags fixture of
        Err e ->
            Expect.fail e

        Ok g ->
            let
                heads =
                    reader g
            in
            if List.isEmpty heads then
                Expect.fail "fixture broken: reader found nothing"

            else if List.all ok heads then
                Expect.pass

            else
                Expect.fail ("expected " ++ what ++ ", got " ++ String.join ", " (List.map describeAnno heads))



-- ====== FIXTURES ======


hInt : Src.Type
hInt =
    tLambda (tType "Int" []) (tType "Int" [])


recT : Src.Type
recT =
    tRecord [ ( "f", hInt ), ( "n", tType "String" [] ) ]


base : List { name : String, args : List Src.Pattern, tipe : Src.Type, body : Src.Expr }
base =
    [ { name = "inc", args = [ pVar "x" ], tipe = hInt, body = binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1) }
    , { name = "dec", args = [ pVar "x" ], tipe = hInt, body = binopsExpr [ ( varExpr "x", "-" ) ] (intExpr 1) }
    , { name = "apply", args = [ pVar "g", pVar "n" ], tipe = tLambda hInt hInt, body = callExpr (varExpr "g") [ varExpr "n" ] }
    ]


{-| `build cb = let r = { f = cb, n = "x" } in useRec r`, `useRec r = apply r.f 2`
(F3-b carries the let; E15 carries the access argument).
-}
argShape : Src.Module
argShape =
    makeModuleWithTypedDefsUnionsAliases "Test"
        (base
            ++ [ { name = "useRec", args = [ pVar "r" ], tipe = tLambda recT (tType "Int" []), body = callExpr (varExpr "apply") [ accessExpr (varExpr "r") "f", intExpr 2 ] }
               , { name = "build"
                 , args = [ pVar "cb" ]
                 , tipe = tLambda hInt (tType "Int" [])
                 , body = letExpr [ define "r" [] (recordExpr [ ( "f", varExpr "cb" ), ( "n", strExpr "x" ) ]) ] (callExpr (varExpr "useRec") [ varExpr "r" ])
                 }
               , { name = "testValue", args = [], tipe = tType "Int" [], body = callExpr (varExpr "build") [ varExpr "inc" ] }
               ]
        )
        []
        []


{-| `useRec r = r.f 2` — the callee IS the access.
-}
calleeShape : Src.Module
calleeShape =
    makeModuleWithTypedDefsUnionsAliases "Test"
        (base
            ++ [ { name = "useRec", args = [ pVar "r" ], tipe = tLambda recT (tType "Int" []), body = callExpr (accessExpr (varExpr "r") "f") [ intExpr 2 ] }
               , { name = "build"
                 , args = [ pVar "cb" ]
                 , tipe = tLambda hInt (tType "Int" [])
                 , body = letExpr [ define "r" [] (recordExpr [ ( "f", varExpr "cb" ), ( "n", strExpr "x" ) ]) ] (callExpr (varExpr "useRec") [ varExpr "r" ])
                 }
               , { name = "testValue", args = [], tipe = tType "Int" [], body = callExpr (varExpr "build") [ varExpr "inc" ] }
               ]
        )
        []
        []


{-| `mk cb = { f = cb, n = "x" }`, `useRec (mk inc)` — the record is RETURNED.
-}
returnedShape : Src.Module
returnedShape =
    makeModuleWithTypedDefsUnionsAliases "Test"
        (base
            ++ [ { name = "useRec", args = [ pVar "r" ], tipe = tLambda recT (tType "Int" []), body = callExpr (varExpr "apply") [ accessExpr (varExpr "r") "f", intExpr 2 ] }
               , { name = "mk", args = [ pVar "cb" ], tipe = tLambda hInt recT, body = recordExpr [ ( "f", varExpr "cb" ), ( "n", strExpr "x" ) ] }
               , { name = "testValue", args = [], tipe = tType "Int" [], body = callExpr (varExpr "useRec") [ callExpr (varExpr "mk") [ varExpr "inc" ] ] }
               ]
        )
        []
        []


{-| `let fs = [ inc, dec ] in useL fs` — a GROUND list literal of two functions.
-}
listShape : Src.Module
listShape =
    makeModuleWithTypedDefsUnionsAliases "Test"
        (base
            ++ [ { name = "useL", args = [ pVar "gs" ], tipe = tLambda (tType "List" [ hInt ]) (tType "Int" []), body = intExpr 0 }
               , { name = "testValue", args = [], tipe = tType "Int" [], body = letExpr [ define "fs" [] (listExpr [ varExpr "inc", varExpr "dec" ]) ] (callExpr (varExpr "useL") [ varExpr "fs" ]) }
               ]
        )
        []
        []



-- ====== HARNESS / READERS ======


runWith : Flags -> Src.Module -> Result String Mono.MonoGraph
runWith flags srcModule =
    let
        defaults =
            Config.defaultLss

        fl =
            Config.defaultLss.flow
    in
    Pipeline.runSolverMonoWithLimits Config.defaultLimits
        { defaults | enabled = True, keyed = True, flow = { fl | letOverlay = flags.letOverlay, accessFlow = flags.accessFlow, litFacts = flags.litFacts } }
        srcModule


entries : String -> Mono.MonoGraph -> List Mono.MonoType
entries target (Mono.MonoGraph g) =
    Array.foldl
        (\entry acc ->
            case entry of
                Just ( Mono.Global _ name, t ) ->
                    if name == target then
                        t :: acc

                    else
                        acc

                _ ->
                    acc
        )
        []
        g.registry.reverseMapping


calleeHeads : String -> Mono.MonoGraph -> List Mono.LambdaSetAnno
calleeHeads target g =
    List.filterMap
        (\t ->
            case t of
                Mono.MFunction _ _ (p0 :: _) _ ->
                    Just (Mono.headAnno p0)

                _ ->
                    Nothing
        )
        (entries target g)


fieldHeads : String -> String -> Mono.MonoGraph -> List Mono.LambdaSetAnno
fieldHeads target field g =
    List.filterMap
        (\t ->
            case t of
                Mono.MFunction _ _ ((Mono.MRecord _ fs) :: _) _ ->
                    Maybe.map Mono.headAnno (Dict.get field fs)

                _ ->
                    Nothing
        )
        (entries target g)


listElemHeads : String -> Mono.MonoGraph -> List Mono.LambdaSetAnno
listElemHeads target g =
    List.filterMap
        (\t ->
            case t of
                Mono.MFunction _ _ ((Mono.MList _ inner) :: _) _ ->
                    Just (Mono.headAnno inner)

                _ ->
                    Nothing
        )
        (entries target g)


{-| The head annotation of every CALL whose callee is a record-field access,
over all nodes.
-}
accessCalleeHeads : Mono.MonoGraph -> List Mono.LambdaSetAnno
accessCalleeHeads (Mono.MonoGraph g) =
    Array.foldl
        (\maybeNode acc ->
            case maybeNode of
                Just node ->
                    List.foldl
                        (\e a ->
                            Traverse.foldExpr
                                (\x acc2 ->
                                    case x of
                                        Mono.MonoCall _ ((Mono.MonoRecordAccess _ _ _) as callee) _ _ _ ->
                                            Mono.headAnno (Mono.typeOf callee) :: acc2

                                        _ ->
                                            acc2
                                )
                                a
                                e
                        )
                        acc
                        (nodeExprs node)

                Nothing ->
                    acc
        )
        []
        g.nodes


nodeExprs : Mono.MonoNode -> List Mono.MonoExpr
nodeExprs node =
    case node of
        Mono.MonoDefine e _ ->
            [ e ]

        Mono.MonoTailFunc _ e _ ->
            [ e ]

        _ ->
            []


isSet : Mono.LambdaSetAnno -> Bool
isSet anno =
    case anno of
        Mono.LSet _ ->
            True

        _ ->
            False


isSingleton : Mono.LambdaSetAnno -> Bool
isSingleton anno =
    case anno of
        Mono.LSet [ _ ] ->
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


isTop : Mono.LambdaSetAnno -> Bool
isTop anno =
    case anno of
        Mono.LTop _ ->
            True

        _ ->
            False


isVar : Mono.LambdaSetAnno -> Bool
isVar anno =
    case anno of
        Mono.LVar _ ->
            True

        Mono.LPartial _ ->
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
            "LTop:" ++ Mono.topKindLabel k

        Mono.LPartial ms ->
            "LPartial[" ++ String.join "," (List.map String.fromInt ms) ++ "]"
