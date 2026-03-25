module SourceIR.BoolCaseCases exposing (expectSuite)

{-| Test cases for boolean case expressions and if-with-terminated-branch.

Targets:

  - MLIR Expr findBoolBranches/generateBoolFanOutWithJumps
  - MLIR Expr generateIfWithTerminatedBranch/Else
  - Decision tree optimization for Bool pattern matching

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , boolExpr
        , callExpr
        , caseExpr
        , ifExpr
        , intExpr
        , listExpr
        , makeKernelModule
        , makeModuleWithDefs
        , makeModuleWithTypedDefs
        , pAnything
        , pCtor
        , pInt
        , pVar
        , recordExpr
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
    Test.test ("Bool case and branch " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "Case on Bool True/False", run = caseOnBool expectFn }
    , { label = "Case on Bool with function", run = caseOnBoolFunc expectFn }
    , { label = "Nested if-else chain", run = nestedIfElse expectFn }
    , { label = "If with complex branches", run = ifComplexBranches expectFn }
    , { label = "Bool case returning different types", run = boolCaseDifferentExprs expectFn }
    , { label = "Multi-branch int case (fanout)", run = multiBranchIntCase expectFn }
    , { label = "Case with record results", run = caseWithRecordResults expectFn }
    , { label = "String escape newline", run = stringEscapeNewline expectFn }
    , { label = "String escape tab", run = stringEscapeTab expectFn }
    , { label = "String escape backslash", run = stringEscapeBackslash expectFn }
    , { label = "String escape quote", run = stringEscapeQuote expectFn }
    , { label = "String with unicode", run = stringUnicode expectFn }
    ]



-- ============================================================================
-- BOOL CASE EXPRESSIONS
-- ============================================================================


caseOnBool : (Src.Module -> Expectation) -> (() -> Expectation)
caseOnBool expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "classify"
                  , [ pVar "b" ]
                  , caseExpr (varExpr "b")
                        [ ( pCtor "True" [], intExpr 1 )
                        , ( pCtor "False" [], intExpr 0 )
                        ]
                  )
                , ( "testValue", [], callExpr (varExpr "classify") [ boolExpr True ] )
                ]
    in
    expectFn modul


caseOnBoolFunc : (Src.Module -> Expectation) -> (() -> Expectation)
caseOnBoolFunc expectFn _ =
    let
        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "boolToString"
                  , args = [ pVar "b" ]
                  , tipe = tLambda (tType "Bool" []) (tType "String" [])
                  , body =
                        caseExpr (varExpr "b")
                            [ ( pCtor "True" [], strExpr "yes" )
                            , ( pCtor "False" [], strExpr "no" )
                            ]
                  }
                , { name = "testValue"
                  , args = []
                  , tipe = tType "String" []
                  , body = callExpr (varExpr "boolToString") [ boolExpr False ]
                  }
                ]
    in
    expectFn modul


nestedIfElse : (Src.Module -> Expectation) -> (() -> Expectation)
nestedIfElse expectFn _ =
    let
        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "classify"
                  , args = [ pVar "n" ]
                  , tipe = tLambda (tType "Int" []) (tType "String" [])
                  , body =
                        ifExpr (binopsExpr [ ( varExpr "n", "<" ) ] (intExpr 0))
                            (strExpr "negative")
                            (ifExpr (binopsExpr [ ( varExpr "n", "==" ) ] (intExpr 0))
                                (strExpr "zero")
                                (strExpr "positive")
                            )
                  }
                , { name = "testValue"
                  , args = []
                  , tipe = tType "String" []
                  , body = callExpr (varExpr "classify") [ intExpr 5 ]
                  }
                ]
    in
    expectFn modul


ifComplexBranches : (Src.Module -> Expectation) -> (() -> Expectation)
ifComplexBranches expectFn _ =
    let
        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "pick"
                  , args = [ pVar "b" ]
                  , tipe = tLambda (tType "Bool" []) (tType "Int" [])
                  , body =
                        ifExpr (varExpr "b")
                            (binopsExpr [ ( intExpr 10, "+" ) ] (intExpr 20))
                            (binopsExpr [ ( intExpr 5, "*" ) ] (intExpr 3))
                  }
                , { name = "testValue"
                  , args = []
                  , tipe = tType "Int" []
                  , body = callExpr (varExpr "pick") [ boolExpr True ]
                  }
                ]
    in
    expectFn modul


boolCaseDifferentExprs : (Src.Module -> Expectation) -> (() -> Expectation)
boolCaseDifferentExprs expectFn _ =
    let
        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "choose"
                  , args = [ pVar "flag" ]
                  , tipe = tLambda (tType "Bool" []) (tType "List" [ tType "Int" [] ])
                  , body =
                        ifExpr (varExpr "flag")
                            (listExpr [ intExpr 1, intExpr 2, intExpr 3 ])
                            (listExpr [])
                  }
                , { name = "testValue"
                  , args = []
                  , tipe = tType "List" [ tType "Int" [] ]
                  , body = callExpr (varExpr "choose") [ boolExpr True ]
                  }
                ]
    in
    expectFn modul


multiBranchIntCase : (Src.Module -> Expectation) -> (() -> Expectation)
multiBranchIntCase expectFn _ =
    let
        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "label"
                  , args = [ pVar "n" ]
                  , tipe = tLambda (tType "Int" []) (tType "String" [])
                  , body =
                        caseExpr (varExpr "n")
                            [ ( pInt 0, strExpr "zero" )
                            , ( pInt 1, strExpr "one" )
                            , ( pInt 2, strExpr "two" )
                            , ( pInt 3, strExpr "three" )
                            , ( pAnything, strExpr "many" )
                            ]
                  }
                , { name = "testValue"
                  , args = []
                  , tipe = tType "String" []
                  , body = callExpr (varExpr "label") [ intExpr 2 ]
                  }
                ]
    in
    expectFn modul


caseWithRecordResults : (Src.Module -> Expectation) -> (() -> Expectation)
caseWithRecordResults expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "pick"
                  , [ pVar "n" ]
                  , caseExpr (varExpr "n")
                        [ ( pInt 0, recordExpr [ ( "x", intExpr 0 ), ( "y", intExpr 0 ) ] )
                        , ( pAnything, recordExpr [ ( "x", intExpr 1 ), ( "y", intExpr 1 ) ] )
                        ]
                  )
                , ( "testValue", [], callExpr (varExpr "pick") [ intExpr 1 ] )
                ]
    in
    expectFn modul



-- ============================================================================
-- STRING ESCAPES (targets decodeEscape/decodeUnicodeEscape in MLIR Expr)
-- ============================================================================


stringEscapeNewline : (Src.Module -> Expectation) -> (() -> Expectation)
stringEscapeNewline expectFn _ =
    expectFn (makeKernelModule "testValue" (strExpr "line1\nline2"))


stringEscapeTab : (Src.Module -> Expectation) -> (() -> Expectation)
stringEscapeTab expectFn _ =
    expectFn (makeKernelModule "testValue" (strExpr "col1\tcol2"))


stringEscapeBackslash : (Src.Module -> Expectation) -> (() -> Expectation)
stringEscapeBackslash expectFn _ =
    expectFn (makeKernelModule "testValue" (strExpr "path\\to\\file"))


stringEscapeQuote : (Src.Module -> Expectation) -> (() -> Expectation)
stringEscapeQuote expectFn _ =
    expectFn (makeKernelModule "testValue" (strExpr "she said \"hello\""))


stringUnicode : (Src.Module -> Expectation) -> (() -> Expectation)
stringUnicode expectFn _ =
    expectFn (makeKernelModule "testValue" (strExpr "hello 😀 world"))
