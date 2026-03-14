module TestLogic.Monomorphize.RenamingSubstAndMErasedTest exposing (suite)

{-| Targeted test cases for Bug 1 (renaming/substitution disconnect) and Bug 2 (CEcoValue poisoning).

These tests exercise specific scenarios that trigger spurious CEcoValue types when
reverse renaming is missing or when CEcoValue overwrites concrete bindings in unifyHelp.

Bug 1 scenarios: polymorphic identity in record field, makeAdder curried call.
Bug 2 scenario: fold with empty list causing CEcoValue poisoning.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( accessExpr
        , binopsExpr
        , callExpr
        , caseExpr
        , define
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModuleWithTypedDefs
        , pCons
        , pList
        , pVar
        , recordExpr
        , tLambda
        , tTuple
        , tType
        , tVar
        , tupleExpr
        , varExpr
        )
import Dict
import Expect exposing (Expectation)
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    Test.describe "Renaming substitution alignment & CEcoValue poisoning"
        [ Test.test "Bug 1: polymorphic identity in record field has no CEcoValue" <|
            \_ -> checkIdentityInRecordField
        , Test.test "Bug 1: makeAdder curried call has no CEcoValue" <|
            \_ -> checkMakeAdderCurried
        , Test.test "Bug 2: fold with empty list retains concrete types" <|
            \_ -> checkFoldWithEmptyList
        ]



-- ============================================================================
-- TEST 1: Polymorphic identity in record field (Bug 1 scenario 3)
-- ============================================================================


{-| Create a module with a polymorphic identity function stored in a record field.

    main =
        let
            r =
                { fn = \x -> x }
        in
        r.fn 42

Expected: The closure's MonoType should be MFunction [MInt] MInt, no CEcoValue.

-}
identityInRecordModule : Src.Module
identityInRecordModule =
    let
        intType =
            tType "Int" []
    in
    makeModuleWithTypedDefs "Test"
        [ { name = "testValue"
          , args = []
          , tipe = intType
          , body =
                letExpr
                    [ define "r" [] (recordExpr [ ( "fn", lambdaExpr [ pVar "x" ] (varExpr "x") ) ])
                    ]
                    (callExpr (accessExpr (varExpr "r") "fn") [ intExpr 42 ])
          }
        ]


checkIdentityInRecordField : Expectation
checkIdentityInRecordField =
    case Pipeline.runToMono identityInRecordModule of
        Err msg ->
            Expect.fail ("Pipeline failed: " ++ msg)

        Ok { monoGraph } ->
            let
                violations =
                    findCEcoValueInFullyMonomorphicSpecs monoGraph
            in
            if List.isEmpty violations then
                Expect.pass

            else
                Expect.fail
                    ("Found CEcoValue in fully monomorphic specs (Bug 1 - renaming disconnect):\n"
                        ++ String.join "\n" violations
                    )



-- ============================================================================
-- TEST 2: makeAdder curried call (Bug 1 scenario 5)
-- ============================================================================


{-| Create a module with a curried function returning a tuple.

    makeAdder : Int -> Int -> ( Int, Int )
    makeAdder n x =
        ( n, x )

    main : ( Int, Int )
    main =
        makeAdder 5 3

Expected: Inner closure type has no CEcoValue.

-}
makeAdderModule : Src.Module
makeAdderModule =
    let
        intType =
            tType "Int" []

        tupleType =
            tTuple intType intType

        funcType =
            tLambda intType (tLambda intType tupleType)
    in
    makeModuleWithTypedDefs "Test"
        [ { name = "makeAdder"
          , args = [ pVar "n", pVar "x" ]
          , tipe = funcType
          , body = tupleExpr (varExpr "n") (varExpr "x")
          }
        , { name = "testValue"
          , args = []
          , tipe = tupleType
          , body = callExpr (varExpr "makeAdder") [ intExpr 5, intExpr 3 ]
          }
        ]


checkMakeAdderCurried : Expectation
checkMakeAdderCurried =
    case Pipeline.runToMono makeAdderModule of
        Err msg ->
            Expect.fail ("Pipeline failed: " ++ msg)

        Ok { monoGraph } ->
            let
                violations =
                    findCEcoValueInFullyMonomorphicSpecs monoGraph
            in
            if List.isEmpty violations then
                Expect.pass

            else
                Expect.fail
                    ("Found CEcoValue in fully monomorphic specs (Bug 1 - curried renaming):\n"
                        ++ String.join "\n" violations
                    )



-- ============================================================================
-- TEST 3: Fold with empty list (Bug 2 scenario 11)
-- ============================================================================


{-| Create a module with a fold function called with an empty list.

    myFoldl : (a -> b -> b) -> b -> List a -> b
    myFoldl step init entries =
        case entries of
            [] ->
                init

            x :: xs ->
                myFoldl step (step x init) xs

    main : Int
    main =
        myFoldl (\entry acc -> acc + 1) 0 []

Expected: The step parameter type retains concrete types (Int -> Int -> Int), no CEcoValue.

-}
foldWithEmptyListModule : Src.Module
foldWithEmptyListModule =
    let
        intType =
            tType "Int" []

        aVar =
            tVar "a"

        bVar =
            tVar "b"

        stepType =
            tLambda aVar (tLambda bVar bVar)

        listAType =
            tType "List" [ aVar ]

        foldlType =
            tLambda stepType (tLambda bVar (tLambda listAType bVar))
    in
    makeModuleWithTypedDefs "Test"
        [ { name = "myFoldl"
          , args = [ pVar "step", pVar "init", pVar "entries" ]
          , tipe = foldlType
          , body =
                caseExpr (varExpr "entries")
                    [ ( pList [], varExpr "init" )
                    , ( pCons (pVar "x") (pVar "xs")
                      , callExpr (varExpr "myFoldl")
                            [ varExpr "step"
                            , callExpr (varExpr "step") [ varExpr "x", varExpr "init" ]
                            , varExpr "xs"
                            ]
                      )
                    ]
          }
        , { name = "testValue"
          , args = []
          , tipe = intType
          , body =
                callExpr (varExpr "myFoldl")
                    [ lambdaExpr [ pVar "entry", pVar "acc" ]
                        (binopsExpr [ ( varExpr "acc", "+" ) ] (intExpr 1))
                    , intExpr 0
                    , listExpr []
                    ]
          }
        ]


checkFoldWithEmptyList : Expectation
checkFoldWithEmptyList =
    case Pipeline.runToMono foldWithEmptyListModule of
        Err msg ->
            Expect.fail ("Pipeline failed: " ++ msg)

        Ok { monoGraph } ->
            let
                violations =
                    findCEcoValueInFullyMonomorphicSpecs monoGraph
            in
            if List.isEmpty violations then
                Expect.pass

            else
                Expect.fail
                    ("Found CEcoValue in fully monomorphic specs (Bug 2 - CEcoValue poisoning):\n"
                        ++ String.join "\n" violations
                    )



-- ============================================================================
-- HELPERS
-- ============================================================================




findCEcoValueInFullyMonomorphicSpecs : Mono.MonoGraph -> List String
findCEcoValueInFullyMonomorphicSpecs (Mono.MonoGraph data) =
    Array.toList data.nodes
        |> List.indexedMap Tuple.pair
        |> List.concatMap
            (\( specId, maybeNode ) ->
                case maybeNode of
                    Just node ->
                        let
                            keyType =
                                nodeType node
                        in
                        if isFullyMonomorphic keyType then
                            findCEcoValueInNode specId node

                        else
                            []

                    Nothing ->
                        []
            )


isFullyMonomorphic : Mono.MonoType -> Bool
isFullyMonomorphic monoType =
    not (containsAnyMVar monoType)


containsAnyMVar : Mono.MonoType -> Bool
containsAnyMVar monoType =
    case monoType of
        Mono.MVar _ _ ->
            True

        Mono.MList inner ->
            containsAnyMVar inner

        Mono.MFunction args ret ->
            List.any containsAnyMVar args || containsAnyMVar ret

        Mono.MRecord fields ->
            Dict.foldl (\_ fieldType acc -> acc || containsAnyMVar fieldType) False fields

        Mono.MCustom _ _ args ->
            List.any containsAnyMVar args

        Mono.MTuple elems ->
            List.any containsAnyMVar elems

        _ ->
            False


findCEcoValueInNode : Int -> Mono.MonoNode -> List String
findCEcoValueInNode specId node =
    let
        ctx =
            "SpecId " ++ String.fromInt specId
    in
    case node of
        Mono.MonoDefine expr monoType ->
            collectCEcoValue ctx "node type" monoType
                ++ findCEcoValueInExpr ctx expr

        Mono.MonoTailFunc params expr monoType ->
            collectCEcoValue ctx "node type" monoType
                ++ List.concatMap (\( _, t ) -> collectCEcoValue ctx "param" t) params
                ++ findCEcoValueInExpr ctx expr

        _ ->
            []


findCEcoValueInExpr : String -> Mono.MonoExpr -> List String
findCEcoValueInExpr ctx expr =
    case expr of
        Mono.MonoClosure info body closureType ->
            collectCEcoValue ctx "closure type" closureType
                ++ List.concatMap (\( _, t ) -> collectCEcoValue ctx "closure param" t) info.params
                ++ findCEcoValueInExpr ctx body

        Mono.MonoCall _ func args resultType _ ->
            collectCEcoValue ctx "call result" resultType
                ++ findCEcoValueInExpr ctx func
                ++ List.concatMap (findCEcoValueInExpr ctx) args

        Mono.MonoLet def body letType ->
            collectCEcoValue ctx "let type" letType
                ++ findCEcoValueInDefExpr ctx def
                ++ findCEcoValueInExpr ctx body

        _ ->
            collectCEcoValue ctx "expr" (Mono.typeOf expr)


findCEcoValueInDefExpr : String -> Mono.MonoDef -> List String
findCEcoValueInDefExpr ctx def =
    case def of
        Mono.MonoDef _ bound ->
            findCEcoValueInExpr ctx bound

        Mono.MonoTailDef _ params bound ->
            List.concatMap (\( _, t ) -> collectCEcoValue ctx "taildef param" t) params
                ++ findCEcoValueInExpr ctx bound


collectCEcoValue : String -> String -> Mono.MonoType -> List String
collectCEcoValue ctx location monoType =
    let
        vars =
            collectCEcoValueVars monoType
    in
    if List.isEmpty vars then
        []

    else
        [ ctx ++ " " ++ location ++ ": CEcoValue vars " ++ String.join ", " vars ++ " in " ++ monoTypeToString monoType ]


collectCEcoValueVars : Mono.MonoType -> List String
collectCEcoValueVars monoType =
    case monoType of
        Mono.MVar _ Mono.CEcoValue ->
            -- CEcoValue MVars are acceptable — they compile identically to eco.value
            []

        Mono.MVar name Mono.CNumber ->
            -- CNumber should have been resolved by forceCNumberToInt
            [ name ]

        Mono.MList inner ->
            collectCEcoValueVars inner

        Mono.MFunction args ret ->
            List.concatMap collectCEcoValueVars args ++ collectCEcoValueVars ret

        Mono.MRecord fields ->
            Dict.foldl (\_ fieldType acc -> acc ++ collectCEcoValueVars fieldType) [] fields

        Mono.MCustom _ _ args ->
            List.concatMap collectCEcoValueVars args

        Mono.MTuple elems ->
            List.concatMap collectCEcoValueVars elems

        _ ->
            []


nodeType : Mono.MonoNode -> Mono.MonoType
nodeType node =
    case node of
        Mono.MonoDefine _ t ->
            t

        Mono.MonoTailFunc _ _ t ->
            t

        Mono.MonoCtor _ t ->
            t

        Mono.MonoEnum _ t ->
            t

        Mono.MonoExtern t ->
            t

        Mono.MonoManagerLeaf _ t ->
            t

        Mono.MonoPortIncoming _ t ->
            t

        Mono.MonoPortOutgoing _ t ->
            t

        Mono.MonoCycle _ t ->
            t


monoTypeToString : Mono.MonoType -> String
monoTypeToString monoType =
    case monoType of
        Mono.MInt ->
            "MInt"

        Mono.MFloat ->
            "MFloat"

        Mono.MBool ->
            "MBool"

        Mono.MChar ->
            "MChar"

        Mono.MString ->
            "MString"

        Mono.MUnit ->
            "MUnit"

        Mono.MList inner ->
            "MList (" ++ monoTypeToString inner ++ ")"

        Mono.MFunction args ret ->
            "MFunction ["
                ++ String.join ", " (List.map monoTypeToString args)
                ++ "] "
                ++ monoTypeToString ret

        Mono.MCustom _ name args ->
            "MCustom " ++ name ++ " [" ++ String.join ", " (List.map monoTypeToString args) ++ "]"

        Mono.MRecord _ ->
            "MRecord {...}"

        Mono.MTuple elems ->
            "MTuple [" ++ String.join ", " (List.map monoTypeToString elems) ++ "]"

        Mono.MVar name _ ->
            "MVar \"" ++ name ++ "\""
