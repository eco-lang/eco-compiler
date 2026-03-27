module SourceIR.CaseSafepointLeakCases exposing (expectSuite)

{-| Tests for non-tail-recursive case expressions where temporaries inside
alternative regions leak via definedSsaVars into the parent scope's safepoints.

The key pattern: a case expression with alternatives that create temporary
!eco.value-typed SSA variables (e.g., function calls, string literals),
followed by a heap allocation that triggers a safepoint.

Unlike IfLetSafepointCases (which targets if-then-else wrapping case),
these target the direct case expression code paths:
  - generateChainForBoolADTWithJumps
  - generateChainGeneralWithJumps
  - generateBoolFanOutWithJumps
  - generateFanOutGeneralWithJumps
-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , binopsExpr
        , callExpr
        , caseExpr
        , ctorExpr
        , define
        , intExpr
        , letExpr
        , listExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pAnything
        , pCtor
        , pVar
        , strExpr
        , tLambda
        , tType
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Case safepoint leak cases " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "Bool case with temporaries then allocation", run = boolCaseWithAlloc expectFn }
    , { label = "Multi-ctor case with temporaries then allocation", run = multiCtorCaseWithAlloc expectFn }
    , { label = "Nested case with temporaries then allocation", run = nestedCaseWithAlloc expectFn }
    , { label = "Case with function call in alternative then allocation", run = caseWithCallThenAlloc expectFn }
    ]


{-| Bool case (2-way) where both branches create a temporary, followed
by a list allocation.

    type Wrapper = Wrap String

    f : Bool -> String -> String -> List String
    f flag a b =
        let
            val = case flag of
                    True -> a
                    False -> b
        in
        val :: []
-}
boolCaseWithAlloc : (Src.Module -> Expectation) -> (() -> Expectation)
boolCaseWithAlloc expectFn _ =
    let
        fDef : TypedDef
        fDef =
            { name = "f"
            , tipe =
                tLambda (tType "Bool" [])
                    (tLambda (tType "String" [])
                        (tLambda (tType "String" [])
                            (tType "List" [ tType "String" [] ])
                        )
                    )
            , args = [ pVar "flag", pVar "a", pVar "b" ]
            , body =
                letExpr
                    [ define "val"
                        []
                        (caseExpr (varExpr "flag")
                            [ ( pCtor "True" [], varExpr "a" )
                            , ( pCtor "False" [], varExpr "b" )
                            ]
                        )
                    ]
                    (binopsExpr [ ( varExpr "val", "::" ) ] (listExpr []))
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "List" [ tType "String" [] ]
            , body = callExpr (varExpr "f") [ ctorExpr "True", strExpr "hello", strExpr "world" ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "Test"
            [ fDef, testValueDef ]
            []
            []
        )


{-| Multi-constructor case (3+ ctors) where alternatives call functions
that create !eco.value temporaries, followed by allocation.

    type Color = Red | Green | Blue

    colorName : Color -> List String
    colorName c =
        let
            name = case c of
                        Red -> "red"
                        Green -> "green"
                        Blue -> "blue"
        in
        name :: []
-}
multiCtorCaseWithAlloc : (Src.Module -> Expectation) -> (() -> Expectation)
multiCtorCaseWithAlloc expectFn _ =
    let
        unions : List UnionDef
        unions =
            [ { name = "Color"
              , args = []
              , ctors =
                    [ { name = "Red", args = [] }
                    , { name = "Green", args = [] }
                    , { name = "Blue", args = [] }
                    ]
              }
            ]

        colorNameDef : TypedDef
        colorNameDef =
            { name = "colorName"
            , tipe =
                tLambda (tType "Color" [])
                    (tType "List" [ tType "String" [] ])
            , args = [ pVar "c" ]
            , body =
                letExpr
                    [ define "name"
                        []
                        (caseExpr (varExpr "c")
                            [ ( pCtor "Red" [], strExpr "red" )
                            , ( pCtor "Green" [], strExpr "green" )
                            , ( pCtor "Blue" [], strExpr "blue" )
                            ]
                        )
                    ]
                    (binopsExpr [ ( varExpr "name", "::" ) ] (listExpr []))
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "List" [ tType "String" [] ]
            , body = callExpr (varExpr "colorName") [ ctorExpr "Green" ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "Test"
            [ colorNameDef, testValueDef ]
            unions
            []
        )


{-| Nested case: outer case selects a value, inner case destructures it.
Both create temporaries. Followed by allocation.

    type Maybe a = Just a | Nothing

    extract : Maybe (Maybe String) -> String -> List String
    extract outer fallback =
        let
            val = case outer of
                    Just inner ->
                        case inner of
                            Just s -> s
                            Nothing -> fallback
                    Nothing -> fallback
        in
        val :: []
-}
nestedCaseWithAlloc : (Src.Module -> Expectation) -> (() -> Expectation)
nestedCaseWithAlloc expectFn _ =
    let
        extractDef : TypedDef
        extractDef =
            { name = "extract"
            , tipe =
                tLambda (tType "Maybe" [ tType "Maybe" [ tType "String" [] ] ])
                    (tLambda (tType "String" [])
                        (tType "List" [ tType "String" [] ])
                    )
            , args = [ pVar "outer", pVar "fallback" ]
            , body =
                letExpr
                    [ define "val"
                        []
                        (caseExpr (varExpr "outer")
                            [ ( pCtor "Just" [ pVar "inner" ]
                              , caseExpr (varExpr "inner")
                                    [ ( pCtor "Just" [ pVar "s" ], varExpr "s" )
                                    , ( pCtor "Nothing" [], varExpr "fallback" )
                                    ]
                              )
                            , ( pCtor "Nothing" [], varExpr "fallback" )
                            ]
                        )
                    ]
                    (binopsExpr [ ( varExpr "val", "::" ) ] (listExpr []))
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "List" [ tType "String" [] ]
            , body =
                callExpr (varExpr "extract")
                    [ callExpr (ctorExpr "Just") [ callExpr (ctorExpr "Just") [ strExpr "found" ] ]
                    , strExpr "missing"
                    ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "Test"
            [ extractDef, testValueDef ]
            []
            []
        )


{-| Case with function calls in alternatives (creating !eco.value temporaries),
followed by record construction (allocation).

    type Action = Greet String | Farewell String

    describe : Action -> List String
    describe action =
        let
            msg = case action of
                    Greet name -> String.append "Hello, " name
                    Farewell name -> String.append "Goodbye, " name
        in
        msg :: []
-}
caseWithCallThenAlloc : (Src.Module -> Expectation) -> (() -> Expectation)
caseWithCallThenAlloc expectFn _ =
    let
        unions : List UnionDef
        unions =
            [ { name = "Action"
              , args = []
              , ctors =
                    [ { name = "Greet", args = [ tType "String" [] ] }
                    , { name = "Farewell", args = [ tType "String" [] ] }
                    ]
              }
            ]

        describeDef : TypedDef
        describeDef =
            { name = "describe"
            , tipe =
                tLambda (tType "Action" [])
                    (tType "List" [ tType "String" [] ])
            , args = [ pVar "action" ]
            , body =
                letExpr
                    [ define "msg"
                        []
                        (caseExpr (varExpr "action")
                            [ ( pCtor "Greet" [ pVar "name" ]
                              , callExpr (varExpr "append") [ strExpr "Hello, ", varExpr "name" ]
                              )
                            , ( pCtor "Farewell" [ pVar "name" ]
                              , callExpr (varExpr "append") [ strExpr "Goodbye, ", varExpr "name" ]
                              )
                            ]
                        )
                    ]
                    (binopsExpr [ ( varExpr "msg", "::" ) ] (listExpr []))
            }

        appendDef : TypedDef
        appendDef =
            { name = "append"
            , tipe = tLambda (tType "String" []) (tLambda (tType "String" []) (tType "String" []))
            , args = [ pVar "a", pVar "b" ]
            , body = callExpr (varExpr "a") []
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "List" [ tType "String" [] ]
            , body =
                callExpr (varExpr "describe")
                    [ callExpr (ctorExpr "Greet") [ strExpr "World" ]
                    ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "Test"
            [ appendDef, describeDef, testValueDef ]
            unions
            []
        )
