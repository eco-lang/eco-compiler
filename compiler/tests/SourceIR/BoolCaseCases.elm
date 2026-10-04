module SourceIR.BoolCaseCases exposing (expectSuite)

{-| Source programs that branch on a `Bool` or on an `Int` literal, and source
programs holding string literals with special characters, for a pipeline stage
to be run over. They give a stage that mishandles a `case` on `True` and
`False`, an `if`/`else` chain or such a literal a program to fail on.

This module only builds the programs. Each case builds a `Src.Module` and
hands it to `expectFn`, the expectation function the caller passes to
`expectSuite`; that function decides which stage the program goes through and
what counts as passing.

The branching cases are built with `makeModuleWithDefs`, whose definitions
have no annotations and whose module imports `Basics` and `List`, or with
`makeModuleWithTypedDefs`, whose definitions are annotated and whose module
imports the standard set (`Basics`, `Maybe`, `List`, `Elm.JsArray`, `String`,
`Char`). The string cases are built with `makeKernelModule`, which imports the
kernel set. In every case the module is named `Test` and has a `testValue`;
in the branching cases `testValue` applies the function under test to one
fixed argument.

A string literal in the Source AST holds the text between the quotes in its
escaped source form: the parser keeps an escape such as `\n` as the two
characters it was written with, and rejects a raw newline in a single-line
string. `strExpr` stores its argument unchanged, and the Elm literals passed to
it in this module are decoded by Elm before it sees them. So the newline and
tab cases hold a real newline and a real tab character, the backslash case
holds single backslashes, and the quote case holds bare `"` characters. None
of these four holds the text the parser would make from the same source; the
unicode case's character is one the parser also keeps as itself.

The cases, in the order `bulkCheck` runs them:

  - "Case on Bool True/False": an unannotated `classify` with a `case` on its
    argument, `True` giving 1 and `False` giving 0, applied to `True`.
  - "Case on Bool with function": `boolToString : Bool -> String`, a `case`
    with `True` giving `"yes"` and `False` giving `"no"`, applied to `False`.
  - "Nested if-else chain": `classify : Int -> String`, an `if` on `n < 0`
    whose `else` is a second `if` on `n == 0`, applied to 5.
  - "If with complex branches": `pick : Bool -> Int`, an `if` on its argument
    whose branches are `10 + 20` and `5 * 3`, applied to `True`.
  - "Bool case returning different types": `choose : Bool -> List Int`, an
    `if` (not a `case`) whose branches are `[ 1, 2, 3 ]` and `[]`, applied to
    `True`. Both branches have the same type.
  - "Multi-branch int case (fanout)": `label : Int -> String`, a `case` with
    branches for 0, 1, 2 and 3 and a wildcard, applied to 2.
  - "Case with record results": an unannotated `pick` with a `case` on its
    argument, 0 giving `{ x = 0, y = 0 }` and a wildcard `{ x = 1, y = 1 }`,
    applied to 1.
  - "String escape newline", "String escape tab", "String escape backslash",
    "String escape quote" and "String with unicode": a `testValue` that is a
    single string literal, holding a newline, a tab, two backslashes, two
    `"` characters, or a character outside the Basic Multilingual Plane
    written as itself.

Among what is not tested: a branch that ends in a tail call; a `case` on a
`Bool` with a wildcard branch; string literals in the escaped form the parser
produces, or written with a `\u{...}` escape.

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


{-| Creates one test, named "Bool case and branch " followed by `condStr`, that
hands each case's module to `expectFn` and runs the cases with
`Compiler.BulkCheck.bulkCheck`. It fails with the label of the first case that
fails, and the cases after that one do not run.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Bool case and branch " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case of this module, labelled, each handing its module to
`expectFn`.
-}
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
-- BRANCHING ON A BOOL OR AN INT
-- ============================================================================


{-| Builds the module of the "Case on Bool True/False" case, described in the
module docstring, and gives it to `expectFn`.
-}
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


{-| Builds the module of the "Case on Bool with function" case, described in the
module docstring, and gives it to `expectFn`.
-}
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


{-| Builds the module of the "Nested if-else chain" case, described in the module
docstring, and gives it to `expectFn`.
-}
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


{-| Builds the module of the "If with complex branches" case, described in the
module docstring, and gives it to `expectFn`.
-}
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


{-| Builds the module of the "Bool case returning different types" case, an `if`
whose two branches are both `List Int`, and gives it to `expectFn`.
-}
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


{-| Builds the module of the "Multi-branch int case (fanout)" case, described in
the module docstring, and gives it to `expectFn`.
-}
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


{-| Builds the module of the "Case with record results" case, described in the
module docstring, and gives it to `expectFn`.
-}
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
-- STRING LITERALS WITH SPECIAL CHARACTERS
-- ============================================================================


{-| Builds a module whose `testValue` is a string literal holding a real newline
character, and gives it to `expectFn`.
-}
stringEscapeNewline : (Src.Module -> Expectation) -> (() -> Expectation)
stringEscapeNewline expectFn _ =
    expectFn (makeKernelModule "testValue" (strExpr "line1\nline2"))


{-| Builds a module whose `testValue` is a string literal holding a real tab
character, and gives it to `expectFn`.
-}
stringEscapeTab : (Src.Module -> Expectation) -> (() -> Expectation)
stringEscapeTab expectFn _ =
    expectFn (makeKernelModule "testValue" (strExpr "col1\tcol2"))


{-| Builds a module whose `testValue` is a string literal holding two single
backslashes, `path\to\file`, and gives it to `expectFn`.
-}
stringEscapeBackslash : (Src.Module -> Expectation) -> (() -> Expectation)
stringEscapeBackslash expectFn _ =
    expectFn (makeKernelModule "testValue" (strExpr "path\\to\\file"))


{-| Builds a module whose `testValue` is a string literal holding two bare `"`
characters, and gives it to `expectFn`.
-}
stringEscapeQuote : (Src.Module -> Expectation) -> (() -> Expectation)
stringEscapeQuote expectFn _ =
    expectFn (makeKernelModule "testValue" (strExpr "she said \"hello\""))


{-| Builds a module whose `testValue` is a string literal holding U+1F600, a
character outside the Basic Multilingual Plane, written as itself, and gives
it to `expectFn`.
-}
stringUnicode : (Src.Module -> Expectation) -> (() -> Expectation)
stringUnicode expectFn _ =
    expectFn (makeKernelModule "testValue" (strExpr "hello 😀 world"))
