module SourceIR.TypeAliasCtorCases exposing (expectSuite, suite)

{-| Test cases for using a type alias name as a record constructor.

In Elm, a type alias to a record generates a constructor function with the
alias name. For example:

    type alias Style = { bold : Bool, count : Int }

generates a constructor function `Style : Bool -> Int -> Style` that can
be called as `Style True 42`.

The bootstrap crash "getOrBuildSchemeInfo: no annotation entry for global
...Style" is triggered when the monomorphizer encounters a type alias
constructor and fails to find an annotation entry because it only looks
for custom type constructors, not alias-derived record constructors.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( AliasDef
        , TypedDef
        , accessExpr
        , boolExpr
        , callExpr
        , ctorExpr
        , define
        , intExpr
        , letExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pVar
        , tLambda
        , tRecord
        , tType
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)
import TestLogic.TestPipeline exposing (expectMonomorphization)


suite : Test
suite =
    Test.describe "Type alias as record constructor"
        [ expectSuite expectMonomorphization "monomorphizes type alias constructors"
        ]


{-| Test suite that can be used with different expectation functions.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Type alias constructor " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "Simple type alias used as record constructor"
      , run = simpleAliasAsCtor expectFn
      }
    , { label = "Type alias constructor passed to a function"
      , run = aliasCtorPassedToFunction expectFn
      }
    ]



-- ============================================================================
-- SIMPLE TYPE ALIAS USED AS RECORD CONSTRUCTOR
-- ============================================================================


{-| A type alias to a record, with the alias name used as a constructor.

    type alias Style = { bold : Bool, count : Int }

    testValue : Int
    testValue =
        let
            s = Style True 42
        in
        s.count

-}
simpleAliasAsCtor : (Src.Module -> Expectation) -> (() -> Expectation)
simpleAliasAsCtor expectFn _ =
    let
        styleAlias : AliasDef
        styleAlias =
            { name = "Style"
            , args = []
            , tipe =
                tRecord
                    [ ( "bold", tType "Bool" [] )
                    , ( "count", tType "Int" [] )
                    ]
            }

        -- testValue : Int
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                letExpr
                    [ define "s" []
                        (callExpr (ctorExpr "Style")
                            [ boolExpr True, intExpr 42 ]
                        )
                    ]
                    (accessExpr (varExpr "s") "count")
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ testValueDef ]
                []
                [ styleAlias ]
    in
    expectFn modul



-- ============================================================================
-- TYPE ALIAS CONSTRUCTOR PASSED TO A FUNCTION
-- ============================================================================


{-| Type alias constructor used to build a record, then passed to a function.

    type alias Style = { bold : Bool, count : Int }

    getCount : Style -> Int
    getCount s = s.count

    testValue : Int
    testValue = getCount (Style True 7)

-}
aliasCtorPassedToFunction : (Src.Module -> Expectation) -> (() -> Expectation)
aliasCtorPassedToFunction expectFn _ =
    let
        styleAlias : AliasDef
        styleAlias =
            { name = "Style"
            , args = []
            , tipe =
                tRecord
                    [ ( "bold", tType "Bool" [] )
                    , ( "count", tType "Int" [] )
                    ]
            }

        -- getCount : Style -> Int
        getCountDef : TypedDef
        getCountDef =
            { name = "getCount"
            , args = [ pVar "s" ]
            , tipe =
                tLambda
                    (tType "Style" [])
                    (tType "Int" [])
            , body =
                accessExpr (varExpr "s") "count"
            }

        -- testValue : Int
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "getCount")
                    [ callExpr (ctorExpr "Style")
                        [ boolExpr True, intExpr 7 ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ getCountDef, testValueDef ]
                []
                [ styleAlias ]
    in
    expectFn modul
