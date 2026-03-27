module SourceIR.IfLetSafepointCases exposing (expectSuite)

{-| Tests for sequential let bindings with if-then-else expressions followed
by allocation.  These exercise the generateIf code path where varMappings
from inside if-branch regions can leak into the parent scope, causing
safepoints to reference cross-region SSA values.

The key pattern: the else branch must contain a pattern match that binds
an Elm variable to an !eco.value-typed value (String, List, custom type).
That binding leaks via varMappings into the parent scope.  A subsequent
allocation triggers a safepoint that picks up the leaked binding.
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
        , ifExpr
        , letExpr
        , listExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pAnything
        , pCons
        , pCtor
        , pList
        , pVar
        , strExpr
        , tLambda
        , tType
        , tVar
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("If-let-safepoint cases " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "If-else with list destructure leaks !eco.value binding", run = ifElseListDestructure expectFn }
    , { label = "If-else with custom type destructure leaks !eco.value binding", run = ifElseCustomDestructure expectFn }
    , { label = "Two sequential if-let with !eco.value leaks", run = twoSequentialIfLet expectFn }
    ]


{-| If-else where the else branch destructures a list, binding the head
(a String = !eco.value).  Followed by list cons allocation.

    f : Bool -> List String -> String -> List String
    f flag items fallback =
        let
            val = if flag then fallback else
                    case items of
                        x :: _ -> x      -- x is String = !eco.value
                        [] -> fallback
        in
        val :: []    -- safepoint before cons; leaked x would appear here
-}
ifElseListDestructure : (Src.Module -> Expectation) -> (() -> Expectation)
ifElseListDestructure expectFn _ =
    let
        fDef : TypedDef
        fDef =
            { name = "f"
            , tipe =
                tLambda (tType "Bool" [])
                    (tLambda (tType "List" [ tType "String" [] ])
                        (tLambda (tType "String" [])
                            (tType "List" [ tType "String" [] ])
                        )
                    )
            , args = [ pVar "flag", pVar "items", pVar "fallback" ]
            , body =
                letExpr
                    [ define "val"
                        []
                        (ifExpr
                                (varExpr "flag")
                                (varExpr "fallback")
                                (caseExpr (varExpr "items")
                                    [ ( pCons (pVar "x") pAnything, varExpr "x" )
                                    , ( pList [], varExpr "fallback" )
                                    ]
                                )
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
                callExpr (varExpr "f")
                    [ ctorExpr "False"
                    , binopsExpr [ ( strExpr "hello", "::" ) ] (listExpr [])
                    , strExpr "default"
                    ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "Test"
            [ fDef, testValueDef ]
            []
            []
        )


{-| If-else where the else branch destructures a custom type with String
fields.  The destructured field (name : String = !eco.value) leaks.

    type Pair = MkPair String String

    g : Bool -> Pair -> String -> List String
    g flag pair fallback =
        let
            val = if flag then fallback else
                    case pair of
                        MkPair name _ -> name    -- name is String = !eco.value
        in
        val :: []
-}
ifElseCustomDestructure : (Src.Module -> Expectation) -> (() -> Expectation)
ifElseCustomDestructure expectFn _ =
    let
        unions : List UnionDef
        unions =
            [ { name = "Pair"
              , args = []
              , ctors =
                    [ { name = "MkPair", args = [ tType "String" [], tType "String" [] ] }
                    ]
              }
            ]

        gDef : TypedDef
        gDef =
            { name = "g"
            , tipe =
                tLambda (tType "Bool" [])
                    (tLambda (tType "Pair" [])
                        (tLambda (tType "String" [])
                            (tType "List" [ tType "String" [] ])
                        )
                    )
            , args = [ pVar "flag", pVar "pair", pVar "fallback" ]
            , body =
                letExpr
                    [ define "val"
                        []
                        (ifExpr
                                (varExpr "flag")
                                (varExpr "fallback")
                                (caseExpr (varExpr "pair")
                                    [ ( pCtor "MkPair" [ pVar "name", pAnything ], varExpr "name" )
                                    ]
                                )
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
                callExpr (varExpr "g")
                    [ ctorExpr "True"
                    , callExpr (ctorExpr "MkPair") [ strExpr "hello", strExpr "world" ]
                    , strExpr "default"
                    ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "Test"
            [ gDef, testValueDef ]
            unions
            []
        )


{-| Two sequential if-let bindings where BOTH else branches destructure
!eco.value fields.  The second safepoint sees leaked bindings from both.

    type Box = Box String

    h : Bool -> Box -> Box -> List String
    h flag b1 b2 =
        let
            x = if flag then "a" else case b1 of Box s1 -> s1
            y = if flag then "b" else case b2 of Box s2 -> s2
        in
        x :: y :: []
-}
twoSequentialIfLet : (Src.Module -> Expectation) -> (() -> Expectation)
twoSequentialIfLet expectFn _ =
    let
        unions : List UnionDef
        unions =
            [ { name = "Box"
              , args = []
              , ctors =
                    [ { name = "Box", args = [ tType "String" [] ] }
                    ]
              }
            ]

        hDef : TypedDef
        hDef =
            { name = "h"
            , tipe =
                tLambda (tType "Bool" [])
                    (tLambda (tType "Box" [])
                        (tLambda (tType "Box" [])
                            (tType "List" [ tType "String" [] ])
                        )
                    )
            , args = [ pVar "flag", pVar "b1", pVar "b2" ]
            , body =
                letExpr
                    [ define "x"
                        []
                        (ifExpr
                            (varExpr "flag")
                            (strExpr "a")
                            (caseExpr (varExpr "b1")
                                [ ( pCtor "Box" [ pVar "s1" ], varExpr "s1" ) ]
                            )
                        )
                    , define "y"
                        []
                        (ifExpr
                            (varExpr "flag")
                            (strExpr "b")
                            (caseExpr (varExpr "b2")
                                [ ( pCtor "Box" [ pVar "s2" ], varExpr "s2" ) ]
                            )
                        )
                    ]
                    (binopsExpr
                        [ ( varExpr "x", "::" ) ]
                        (binopsExpr [ ( varExpr "y", "::" ) ] (listExpr []))
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "List" [ tType "String" [] ]
            , body =
                callExpr (varExpr "h")
                    [ ctorExpr "True"
                    , callExpr (ctorExpr "Box") [ strExpr "hello" ]
                    , callExpr (ctorExpr "Box") [ strExpr "world" ]
                    ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "Test"
            [ hDef, testValueDef ]
            unions
            []
        )
