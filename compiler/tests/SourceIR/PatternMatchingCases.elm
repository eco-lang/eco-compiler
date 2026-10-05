module SourceIR.PatternMatchingCases exposing (expectSuite, suite)

{-| Small programs that use character, string, constructor, tuple and list
patterns in `case` expressions, so that a compiler stage checked against them
is given each of these pattern forms in a program short enough to read when it
fails.

The module asserts nothing itself. `expectSuite` checks the cases in order
with an expectation function the caller supplies, in one elm-test test, through
`Compiler.BulkCheck.bulkCheck`, which stops at the first case that fails and
reports its label. `suite` does the same with
`TestLogic.TestPipeline.expectMonomorphization`.

Each case builds one module named `Test` with
`makeModuleWithTypedDefsUnionsAliases`. It declares one function annotated with
a concrete type, any custom types that function matches on, and an annotated
`testValue` that applies the function to its arguments. In every case but
"Triple pattern" the function takes one argument and its body is a single
`case` on it; in "Triple pattern" it takes three and its body is a `case` on a
three-element tuple of them.

The programs are built as Source AST rather than parsed, and two forms in them
are ones the parser never gives. Sixteen of the twenty-six cases use
`pVar "_"`, a pattern that binds a variable named `_`, where a parsed `_` is the
wildcard; below this is called a `_` variable, and "the wildcard" means
`pAnything`. And three cases give `-1` as a branch result, built as a negative
integer literal, where a parsed `-1` is the negation of `1`.

What the cases build, by section:

  - Char patterns: five functions from `Char` that match two, four, three, five
    and ten character literals, each with a `_` variable last.
  - String patterns: four functions from `String` that match two, seven, four
    and four string literals, each with a `_` variable last.
  - Nested patterns: two functions on a recursive `Tree` whose constructor
    patterns hold only variables, and two that match a single-constructor type
    inside another, `Container (Wrap n)` and `Box (Pair a b)`.
  - Fallback patterns: a match on one constructor of a four-constructor type
    followed by the wildcard, and three matches on integer literals followed by
    a variable branch. In two of these the variable is `x`, tested with `if`.
  - Tuple patterns: `( a, b )`, `( a, _ )` with the wildcard, and
    `( ( a, b ), c )`, each the only branch, and `( x, y, z )` matched against
    a three-element tuple built from the function's three `Int` arguments.
  - List patterns: `[]`, `_ :: []`, `a :: b :: []`, `_ :: rest` in a recursive
    length, and `first :: _` on a `List (List Int)`, each made exhaustive by a
    `[]` branch or a trailing `_` variable.

Among what is not tested:

  - The value a program computes. No case here checks it.
  - Record, unit and `as` patterns.
  - Custom types with type parameters.
  - A character, string or integer literal pattern inside another pattern.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , binopsExpr
        , boolExpr
        , callExpr
        , caseExpr
        , chrExpr
        , ctorExpr
        , ifExpr
        , intExpr
        , listExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pAnything
        , pChr
        , pCons
        , pCtor
        , pInt
        , pList
        , pStr
        , pTuple
        , pTuple3
        , pVar
        , strExpr
        , tLambda
        , tTuple
        , tType
        , tuple3Expr
        , tupleExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)
import TestLogic.TestPipeline exposing (expectMonomorphization)


{-| A standalone test that checks the cases here in order with
`TestLogic.TestPipeline.expectMonomorphization`, stopping at the first that
fails.
-}
suite : Test
suite =
    Test.describe "Pattern matching coverage"
        [ expectSuite expectMonomorphization "monomorphizes patterns"
        ]


{-| Builds one test, named "Pattern matching " followed by `condStr`, that
checks the cases here in order with `expectFn` through
`Compiler.BulkCheck.bulkCheck`. It stops at the first case that fails and names
it.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Pattern matching " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case in this module, section by section in the order the
sections appear, each to be checked with `expectFn`.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.concat
        [ charPatternCases expectFn
        , stringPatternCases expectFn
        , nestedPatternCases expectFn
        , fallbackPatternCases expectFn
        , tuplePatternCases expectFn
        , listPatternCases expectFn
        ]



-- ============================================================================
-- CHAR PATTERN TESTS
-- ============================================================================


{-| Returns the cases that match a `Char` against character literals, each
to be checked with `expectFn`.
-}
charPatternCases : (Src.Module -> Expectation) -> List TestCase
charPatternCases expectFn =
    [ { label = "Simple char pattern", run = simpleCharPatternTest expectFn }
    , { label = "Multiple char patterns", run = multipleCharPatternsTest expectFn }
    , { label = "Char pattern with fallback", run = charPatternWithFallbackTest expectFn }
    , { label = "Vowel detection", run = vowelDetectionTest expectFn }
    , { label = "Digit char pattern", run = digitCharPatternTest expectFn }
    ]


{-| Checks with `expectFn` a program whose `charName : Char -> String`
matches `'a'` and `'b'`, then a `_` variable. `testValue` is `charName 'a'`.
-}
simpleCharPatternTest : (Src.Module -> Expectation) -> (() -> Expectation)
simpleCharPatternTest expectFn _ =
    let
        charNameDef : TypedDef
        charNameDef =
            { name = "charName"
            , args = [ pVar "c" ]
            , tipe = tLambda (tType "Char" []) (tType "String" [])
            , body =
                caseExpr (varExpr "c")
                    [ ( pChr "a", strExpr "letter a" )
                    , ( pChr "b", strExpr "letter b" )
                    , ( pVar "_", strExpr "other" )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "String" []
            , body = callExpr (varExpr "charName") [ chrExpr "a" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ charNameDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Checks with `expectFn` a program whose `charType : Char -> Int` matches
`'0'` to `'3'`, then a `_` variable giving `-1`. `testValue` is
`charType '2'`.
-}
multipleCharPatternsTest : (Src.Module -> Expectation) -> (() -> Expectation)
multipleCharPatternsTest expectFn _ =
    let
        charTypeDef : TypedDef
        charTypeDef =
            { name = "charType"
            , args = [ pVar "c" ]
            , tipe = tLambda (tType "Char" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "c")
                    [ ( pChr "0", intExpr 0 )
                    , ( pChr "1", intExpr 1 )
                    , ( pChr "2", intExpr 2 )
                    , ( pChr "3", intExpr 3 )
                    , ( pVar "_", intExpr -1 )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "charType") [ chrExpr "2" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ charTypeDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Checks with `expectFn` a program whose `isSpecial : Char -> Bool`
matches `'@'`, `'#'` and `'$'`, then a `_` variable. `testValue` is
`isSpecial '@'`.
-}
charPatternWithFallbackTest : (Src.Module -> Expectation) -> (() -> Expectation)
charPatternWithFallbackTest expectFn _ =
    let
        isSpecialDef : TypedDef
        isSpecialDef =
            { name = "isSpecial"
            , args = [ pVar "c" ]
            , tipe = tLambda (tType "Char" []) (tType "Bool" [])
            , body =
                caseExpr (varExpr "c")
                    [ ( pChr "@", boolExpr True )
                    , ( pChr "#", boolExpr True )
                    , ( pChr "$", boolExpr True )
                    , ( pVar "_", boolExpr False )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = callExpr (varExpr "isSpecial") [ chrExpr "@" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ isSpecialDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Checks with `expectFn` a program whose `isVowel : Char -> Bool` matches
the five lower-case vowels, then a `_` variable. `testValue` is `isVowel 'e'`.
-}
vowelDetectionTest : (Src.Module -> Expectation) -> (() -> Expectation)
vowelDetectionTest expectFn _ =
    let
        isVowelDef : TypedDef
        isVowelDef =
            { name = "isVowel"
            , args = [ pVar "c" ]
            , tipe = tLambda (tType "Char" []) (tType "Bool" [])
            , body =
                caseExpr (varExpr "c")
                    [ ( pChr "a", boolExpr True )
                    , ( pChr "e", boolExpr True )
                    , ( pChr "i", boolExpr True )
                    , ( pChr "o", boolExpr True )
                    , ( pChr "u", boolExpr True )
                    , ( pVar "_", boolExpr False )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = callExpr (varExpr "isVowel") [ chrExpr "e" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ isVowelDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Checks with `expectFn` a program whose `digitToInt : Char -> Int`
matches `'0'` to `'9'`, then a `_` variable giving `-1`. `testValue` is
`digitToInt '7'`.
-}
digitCharPatternTest : (Src.Module -> Expectation) -> (() -> Expectation)
digitCharPatternTest expectFn _ =
    let
        digitToIntDef : TypedDef
        digitToIntDef =
            { name = "digitToInt"
            , args = [ pVar "c" ]
            , tipe = tLambda (tType "Char" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "c")
                    [ ( pChr "0", intExpr 0 )
                    , ( pChr "1", intExpr 1 )
                    , ( pChr "2", intExpr 2 )
                    , ( pChr "3", intExpr 3 )
                    , ( pChr "4", intExpr 4 )
                    , ( pChr "5", intExpr 5 )
                    , ( pChr "6", intExpr 6 )
                    , ( pChr "7", intExpr 7 )
                    , ( pChr "8", intExpr 8 )
                    , ( pChr "9", intExpr 9 )
                    , ( pVar "_", intExpr -1 )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "digitToInt") [ chrExpr "7" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ digitToIntDef, testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- STRING PATTERN TESTS
-- ============================================================================


{-| Returns the cases that match a `String` against string literals, each to
be checked with `expectFn`.
-}
stringPatternCases : (Src.Module -> Expectation) -> List TestCase
stringPatternCases expectFn =
    [ { label = "Simple string pattern", run = simpleStringPatternTest expectFn }
    , { label = "Multiple string patterns", run = multipleStringPatternsTest expectFn }
    , { label = "Greeting pattern", run = greetingPatternTest expectFn }
    , { label = "Command pattern", run = commandPatternTest expectFn }
    ]


{-| Checks with `expectFn` a program whose `greet : String -> String`
matches `"Alice"` and `"Bob"`, then a `_` variable. `testValue` is
`greet "Alice"`.
-}
simpleStringPatternTest : (Src.Module -> Expectation) -> (() -> Expectation)
simpleStringPatternTest expectFn _ =
    let
        greetDef : TypedDef
        greetDef =
            { name = "greet"
            , args = [ pVar "name" ]
            , tipe = tLambda (tType "String" []) (tType "String" [])
            , body =
                caseExpr (varExpr "name")
                    [ ( pStr "Alice", strExpr "Hello Alice!" )
                    , ( pStr "Bob", strExpr "Hi Bob!" )
                    , ( pVar "_", strExpr "Hello stranger" )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "String" []
            , body = callExpr (varExpr "greet") [ strExpr "Alice" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ greetDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Checks with `expectFn` a program whose `dayNumber : String -> Int`
matches the seven day names from `"Monday"` to `"Sunday"`, then a `_`
variable. `testValue` is `dayNumber "Wednesday"`.
-}
multipleStringPatternsTest : (Src.Module -> Expectation) -> (() -> Expectation)
multipleStringPatternsTest expectFn _ =
    let
        dayNumberDef : TypedDef
        dayNumberDef =
            { name = "dayNumber"
            , args = [ pVar "day" ]
            , tipe = tLambda (tType "String" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "day")
                    [ ( pStr "Monday", intExpr 1 )
                    , ( pStr "Tuesday", intExpr 2 )
                    , ( pStr "Wednesday", intExpr 3 )
                    , ( pStr "Thursday", intExpr 4 )
                    , ( pStr "Friday", intExpr 5 )
                    , ( pStr "Saturday", intExpr 6 )
                    , ( pStr "Sunday", intExpr 7 )
                    , ( pVar "_", intExpr 0 )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "dayNumber") [ strExpr "Wednesday" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ dayNumberDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Checks with `expectFn` a program whose `respond : String -> String`
matches `"hello"`, `"hi"`, `"hey"` and `"goodbye"`, then a `_` variable.
`testValue` is `respond "hello"`.
-}
greetingPatternTest : (Src.Module -> Expectation) -> (() -> Expectation)
greetingPatternTest expectFn _ =
    let
        respondDef : TypedDef
        respondDef =
            { name = "respond"
            , args = [ pVar "greeting" ]
            , tipe = tLambda (tType "String" []) (tType "String" [])
            , body =
                caseExpr (varExpr "greeting")
                    [ ( pStr "hello", strExpr "Hello to you too!" )
                    , ( pStr "hi", strExpr "Hi there!" )
                    , ( pStr "hey", strExpr "Hey!" )
                    , ( pStr "goodbye", strExpr "Goodbye!" )
                    , ( pVar "_", strExpr "I don't understand" )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "String" []
            , body = callExpr (varExpr "respond") [ strExpr "hello" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ respondDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Checks with `expectFn` a program whose `executeCommand : String -> Int`
matches `"start"`, `"stop"`, `"restart"` and `"status"`, then a `_` variable.
`testValue` is `executeCommand "restart"`.
-}
commandPatternTest : (Src.Module -> Expectation) -> (() -> Expectation)
commandPatternTest expectFn _ =
    let
        executeCommandDef : TypedDef
        executeCommandDef =
            { name = "executeCommand"
            , args = [ pVar "cmd" ]
            , tipe = tLambda (tType "String" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "cmd")
                    [ ( pStr "start", intExpr 1 )
                    , ( pStr "stop", intExpr 2 )
                    , ( pStr "restart", intExpr 3 )
                    , ( pStr "status", intExpr 4 )
                    , ( pVar "_", intExpr 0 )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "executeCommand") [ strExpr "restart" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ executeCommandDef, testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- NESTED PATTERN TESTS
-- ============================================================================


{-| Returns the cases that match custom-type constructors, each to be checked
with `expectFn`.
-}
nestedPatternCases : (Src.Module -> Expectation) -> List TestCase
nestedPatternCases expectFn =
    [ { label = "Nested constructor pattern", run = nestedConstructorPatternTest expectFn }
    , { label = "Tree depth with nested patterns", run = treeDepthTest expectFn }
    , { label = "Double nested pattern", run = doubleNestedPatternTest expectFn }
    , { label = "Pattern in pattern", run = patternInPatternTest expectFn }
    ]


{-| Checks with `expectFn` a program that declares
`type Tree = Leaf Int | Node Tree Tree` and whose `sumTree : Tree -> Int`
matches `Leaf n` and `Node left right`, adding the results of calling itself on
both subtrees. Both constructor patterns hold only variables.
`testValue` is `sumTree (Node (Leaf 1) (Leaf 2))`.
-}
nestedConstructorPatternTest : (Src.Module -> Expectation) -> (() -> Expectation)
nestedConstructorPatternTest expectFn _ =
    let
        treeUnion : UnionDef
        treeUnion =
            { name = "Tree"
            , args = []
            , ctors =
                [ { name = "Leaf", args = [ tType "Int" [] ] }
                , { name = "Node", args = [ tType "Tree" [], tType "Tree" [] ] }
                ]
            }

        sumTreeDef : TypedDef
        sumTreeDef =
            { name = "sumTree"
            , args = [ pVar "tree" ]
            , tipe = tLambda (tType "Tree" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "tree")
                    [ ( pCtor "Leaf" [ pVar "n" ], varExpr "n" )
                    , ( pCtor "Node" [ pVar "left", pVar "right" ]
                      , binopsExpr
                            [ ( callExpr (varExpr "sumTree") [ varExpr "left" ], "+" ) ]
                            (callExpr (varExpr "sumTree") [ varExpr "right" ])
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "sumTree")
                    [ callExpr (ctorExpr "Node")
                        [ callExpr (ctorExpr "Leaf") [ intExpr 1 ]
                        , callExpr (ctorExpr "Leaf") [ intExpr 2 ]
                        ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ sumTreeDef, testValueDef ]
                [ treeUnion ]
                []
    in
    expectFn modul


{-| Checks with `expectFn` a program that declares
`type Tree = Leaf Int | Node Tree Tree` and whose `depth : Tree -> Int` matches
`Leaf` with a `_` variable, giving `1`, and `Node left right`, giving
`1 + max (depth left) (depth right)`. Both constructor patterns hold only
variables. `testValue` is `depth (Node (Node (Leaf 1) (Leaf 2)) (Leaf 3))`.
-}
treeDepthTest : (Src.Module -> Expectation) -> (() -> Expectation)
treeDepthTest expectFn _ =
    let
        treeUnion : UnionDef
        treeUnion =
            { name = "Tree"
            , args = []
            , ctors =
                [ { name = "Leaf", args = [ tType "Int" [] ] }
                , { name = "Node", args = [ tType "Tree" [], tType "Tree" [] ] }
                ]
            }

        depthDef : TypedDef
        depthDef =
            { name = "depth"
            , args = [ pVar "tree" ]
            , tipe = tLambda (tType "Tree" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "tree")
                    [ ( pCtor "Leaf" [ pVar "_" ], intExpr 1 )
                    , ( pCtor "Node" [ pVar "left", pVar "right" ]
                      , binopsExpr
                            [ ( intExpr 1, "+" ) ]
                            (callExpr (varExpr "max")
                                [ callExpr (varExpr "depth") [ varExpr "left" ]
                                , callExpr (varExpr "depth") [ varExpr "right" ]
                                ]
                            )
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "depth")
                    [ callExpr (ctorExpr "Node")
                        [ callExpr (ctorExpr "Node")
                            [ callExpr (ctorExpr "Leaf") [ intExpr 1 ]
                            , callExpr (ctorExpr "Leaf") [ intExpr 2 ]
                            ]
                        , callExpr (ctorExpr "Leaf") [ intExpr 3 ]
                        ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ depthDef, testValueDef ]
                [ treeUnion ]
                []
    in
    expectFn modul


{-| Checks with `expectFn` a program that declares `type Wrapper = Wrap Int`
and `type Container = Container Wrapper`, and whose
`extract : Container -> Int` has the one branch `Container (Wrap n)`.
`testValue` is `extract (Container (Wrap 42))`.
-}
doubleNestedPatternTest : (Src.Module -> Expectation) -> (() -> Expectation)
doubleNestedPatternTest expectFn _ =
    let
        wrapperUnion : UnionDef
        wrapperUnion =
            { name = "Wrapper"
            , args = []
            , ctors =
                [ { name = "Wrap", args = [ tType "Int" [] ] }
                ]
            }

        containerUnion : UnionDef
        containerUnion =
            { name = "Container"
            , args = []
            , ctors =
                [ { name = "Container", args = [ tType "Wrapper" [] ] }
                ]
            }

        extractDef : TypedDef
        extractDef =
            { name = "extract"
            , args = [ pVar "container" ]
            , tipe = tLambda (tType "Container" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "container")
                    [ ( pCtor "Container" [ pCtor "Wrap" [ pVar "n" ] ], varExpr "n" )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "extract")
                    [ callExpr (ctorExpr "Container")
                        [ callExpr (ctorExpr "Wrap") [ intExpr 42 ] ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ extractDef, testValueDef ]
                [ wrapperUnion, containerUnion ]
                []
    in
    expectFn modul


{-| Checks with `expectFn` a program that declares
`type Pair = Pair Int Int` and `type Box = Box Pair`, and whose
`sumBox : Box -> Int` has the one branch `Box (Pair a b)`, giving `a + b`.
`testValue` is `sumBox (Box (Pair 10 20))`.
-}
patternInPatternTest : (Src.Module -> Expectation) -> (() -> Expectation)
patternInPatternTest expectFn _ =
    let
        pairUnion : UnionDef
        pairUnion =
            { name = "Pair"
            , args = []
            , ctors =
                [ { name = "Pair", args = [ tType "Int" [], tType "Int" [] ] }
                ]
            }

        boxUnion : UnionDef
        boxUnion =
            { name = "Box"
            , args = []
            , ctors =
                [ { name = "Box", args = [ tType "Pair" [] ] }
                ]
            }

        sumBoxDef : TypedDef
        sumBoxDef =
            { name = "sumBox"
            , args = [ pVar "box" ]
            , tipe = tLambda (tType "Box" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "box")
                    [ ( pCtor "Box" [ pCtor "Pair" [ pVar "a", pVar "b" ] ]
                      , binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "sumBox")
                    [ callExpr (ctorExpr "Box")
                        [ callExpr (ctorExpr "Pair") [ intExpr 10, intExpr 20 ] ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ sumBoxDef, testValueDef ]
                [ pairUnion, boxUnion ]
                []
    in
    expectFn modul



-- ============================================================================
-- FALLBACK PATTERN TESTS
-- ============================================================================


{-| Returns the cases whose last branch matches every value the branches
before it do not, each to be checked with `expectFn`.
-}
fallbackPatternCases : (Src.Module -> Expectation) -> List TestCase
fallbackPatternCases expectFn =
    [ { label = "Wildcard fallback", run = wildcardFallbackTest expectFn }
    , { label = "Variable capture fallback", run = variableCaptureFallbackTest expectFn }
    , { label = "Multiple specific then fallback", run = multipleSpecificThenFallbackTest expectFn }
    , { label = "Conditional in fallback", run = conditionalInFallbackTest expectFn }
    ]


{-| Checks with `expectFn` a program that declares
`type Status = Success | Error | Pending | Unknown` and whose
`isSuccess : Status -> Bool` matches `Success`, then the wildcard. `testValue`
is `isSuccess Success`.
-}
wildcardFallbackTest : (Src.Module -> Expectation) -> (() -> Expectation)
wildcardFallbackTest expectFn _ =
    let
        statusUnion : UnionDef
        statusUnion =
            { name = "Status"
            , args = []
            , ctors =
                [ { name = "Success", args = [] }
                , { name = "Error", args = [] }
                , { name = "Pending", args = [] }
                , { name = "Unknown", args = [] }
                ]
            }

        isSuccessDef : TypedDef
        isSuccessDef =
            { name = "isSuccess"
            , args = [ pVar "status" ]
            , tipe = tLambda (tType "Status" []) (tType "Bool" [])
            , body =
                caseExpr (varExpr "status")
                    [ ( pCtor "Success" [], boolExpr True )
                    , ( pAnything, boolExpr False )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = callExpr (varExpr "isSuccess") [ ctorExpr "Success" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ isSuccessDef, testValueDef ]
                [ statusUnion ]
                []
    in
    expectFn modul


{-| Checks with `expectFn` a program whose `classify : Int -> String`
matches `0` and `1`, then binds `x` and gives `"positive"` if `x > 0` and
`"negative"` otherwise. `testValue` is `classify 5`.
-}
variableCaptureFallbackTest : (Src.Module -> Expectation) -> (() -> Expectation)
variableCaptureFallbackTest expectFn _ =
    let
        classifyDef : TypedDef
        classifyDef =
            { name = "classify"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "String" [])
            , body =
                caseExpr (varExpr "n")
                    [ ( pInt 0, strExpr "zero" )
                    , ( pInt 1, strExpr "one" )
                    , ( pVar "x"
                      , ifExpr
                            (binopsExpr [ ( varExpr "x", ">" ) ] (intExpr 0))
                            (strExpr "positive")
                            (strExpr "negative")
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "String" []
            , body = callExpr (varExpr "classify") [ intExpr 5 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ classifyDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Checks with `expectFn` a program whose `fibBase : Int -> Int` matches
each of `0` to `5`, then a `_` variable giving `-1`. `testValue` is
`fibBase 4`.
-}
multipleSpecificThenFallbackTest : (Src.Module -> Expectation) -> (() -> Expectation)
multipleSpecificThenFallbackTest expectFn _ =
    let
        fibBaseDef : TypedDef
        fibBaseDef =
            { name = "fibBase"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "n")
                    [ ( pInt 0, intExpr 0 )
                    , ( pInt 1, intExpr 1 )
                    , ( pInt 2, intExpr 1 )
                    , ( pInt 3, intExpr 2 )
                    , ( pInt 4, intExpr 3 )
                    , ( pInt 5, intExpr 5 )
                    , ( pVar "_", intExpr -1 )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "fibBase") [ intExpr 4 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ fibBaseDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Checks with `expectFn` a program whose `clampedValue : Int -> Int`
matches `0`, then binds `x` and gives `0` if `x < 0`, `100` if `x > 100`, and
`x` otherwise, the second test being an `if` in the first one's `else` branch.
`testValue` is `clampedValue 150`.
-}
conditionalInFallbackTest : (Src.Module -> Expectation) -> (() -> Expectation)
conditionalInFallbackTest expectFn _ =
    let
        clampedValueDef : TypedDef
        clampedValueDef =
            { name = "clampedValue"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "n")
                    [ ( pInt 0, intExpr 0 )
                    , ( pVar "x"
                      , ifExpr
                            (binopsExpr [ ( varExpr "x", "<" ) ] (intExpr 0))
                            (intExpr 0)
                            (ifExpr
                                (binopsExpr [ ( varExpr "x", ">" ) ] (intExpr 100))
                                (intExpr 100)
                                (varExpr "x")
                            )
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "clampedValue") [ intExpr 150 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ clampedValueDef, testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- TUPLE PATTERN TESTS
-- ============================================================================


{-| Returns the cases labelled as tuple patterns, each to be checked with
`expectFn`.
-}
tuplePatternCases : (Src.Module -> Expectation) -> List TestCase
tuplePatternCases expectFn =
    [ { label = "Simple tuple pattern", run = simpleTuplePatternTest expectFn }
    , { label = "Tuple with wildcard", run = tupleWithWildcardTest expectFn }
    , { label = "Nested tuple pattern", run = nestedTuplePatternTest expectFn }
    , { label = "Triple pattern", run = triplePatternTest expectFn }
    ]


{-| Checks with `expectFn` a program whose `sumPair : ( Int, Int ) -> Int`
has the one branch `( a, b )`, giving `a + b`. `testValue` is
`sumPair ( 3, 4 )`.
-}
simpleTuplePatternTest : (Src.Module -> Expectation) -> (() -> Expectation)
simpleTuplePatternTest expectFn _ =
    let
        sumPairDef : TypedDef
        sumPairDef =
            { name = "sumPair"
            , args = [ pVar "pair" ]
            , tipe = tLambda (tTuple (tType "Int" []) (tType "Int" [])) (tType "Int" [])
            , body =
                caseExpr (varExpr "pair")
                    [ ( pTuple (pVar "a") (pVar "b")
                      , binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "sumPair") [ tupleExpr (intExpr 3) (intExpr 4) ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ sumPairDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Checks with `expectFn` a program whose `getFirst : ( Int, Int ) -> Int`
has the one branch `( a, _ )`, with the wildcard second. `testValue` is
`getFirst ( 10, 20 )`.
-}
tupleWithWildcardTest : (Src.Module -> Expectation) -> (() -> Expectation)
tupleWithWildcardTest expectFn _ =
    let
        getFirstDef : TypedDef
        getFirstDef =
            { name = "getFirst"
            , args = [ pVar "pair" ]
            , tipe = tLambda (tTuple (tType "Int" []) (tType "Int" [])) (tType "Int" [])
            , body =
                caseExpr (varExpr "pair")
                    [ ( pTuple (pVar "a") pAnything, varExpr "a" ) ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "getFirst") [ tupleExpr (intExpr 10) (intExpr 20) ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ getFirstDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Checks with `expectFn` a program whose
`sumNested : ( ( Int, Int ), Int ) -> Int` has the one branch
`( ( a, b ), c )`, giving `a + b + c`. `testValue` is
`sumNested ( ( 1, 2 ), 3 )`.
-}
nestedTuplePatternTest : (Src.Module -> Expectation) -> (() -> Expectation)
nestedTuplePatternTest expectFn _ =
    let
        sumNestedDef : TypedDef
        sumNestedDef =
            { name = "sumNested"
            , args = [ pVar "nested" ]
            , tipe =
                tLambda
                    (tTuple
                        (tTuple (tType "Int" []) (tType "Int" []))
                        (tType "Int" [])
                    )
                    (tType "Int" [])
            , body =
                caseExpr (varExpr "nested")
                    [ ( pTuple (pTuple (pVar "a") (pVar "b")) (pVar "c")
                      , binopsExpr [ ( varExpr "a", "+" ), ( varExpr "b", "+" ) ] (varExpr "c")
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "sumNested")
                    [ tupleExpr (tupleExpr (intExpr 1) (intExpr 2)) (intExpr 3) ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ sumNestedDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Checks with `expectFn` a program whose
`sumTriple : Int -> Int -> Int -> Int` matches the three-element tuple
`( a, b, c )` of its arguments against the pattern `( x, y, z )` and gives
`x + y + z`. `testValue` is `sumTriple 1 2 3`.
-}
triplePatternTest : (Src.Module -> Expectation) -> (() -> Expectation)
triplePatternTest expectFn _ =
    let
        sumTripleDef : TypedDef
        sumTripleDef =
            { name = "sumTriple"
            , args = [ pVar "a", pVar "b", pVar "c" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" []) (tType "Int" []))
                    )
            , body =
                caseExpr (tuple3Expr (varExpr "a") (varExpr "b") (varExpr "c"))
                    [ ( pTuple3 (pVar "x") (pVar "y") (pVar "z")
                      , binopsExpr [ ( varExpr "x", "+" ), ( varExpr "y", "+" ) ] (varExpr "z")
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "sumTriple") [ intExpr 1, intExpr 2, intExpr 3 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ sumTripleDef, testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- LIST PATTERN TESTS
-- ============================================================================


{-| Returns the cases that match a list against `[]` and `::` patterns, each
to be checked with `expectFn`.
-}
listPatternCases : (Src.Module -> Expectation) -> List TestCase
listPatternCases expectFn =
    [ { label = "Empty list pattern", run = emptyListPatternTest expectFn }
    , { label = "Single element pattern", run = singleElementPatternTest expectFn }
    , { label = "Two element pattern", run = twoElementPatternTest expectFn }
    , { label = "Head tail pattern", run = headTailPatternTest expectFn }
    , { label = "Nested list pattern", run = nestedListPatternTest expectFn }
    ]


{-| Checks with `expectFn` a program whose `isEmpty : List Int -> Bool`
matches `[]`, then a `_` variable. `testValue` is `isEmpty []`.
-}
emptyListPatternTest : (Src.Module -> Expectation) -> (() -> Expectation)
emptyListPatternTest expectFn _ =
    let
        isEmptyDef : TypedDef
        isEmptyDef =
            { name = "isEmpty"
            , args = [ pVar "xs" ]
            , tipe = tLambda (tType "List" [ tType "Int" [] ]) (tType "Bool" [])
            , body =
                caseExpr (varExpr "xs")
                    [ ( pList [], boolExpr True )
                    , ( pVar "_", boolExpr False )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = callExpr (varExpr "isEmpty") [ listExpr [] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ isEmptyDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Checks with `expectFn` a program whose `isSingleton : List Int -> Bool`
matches `_ :: []`, whose head is a `_` variable, then a `_` variable.
`testValue` is `isSingleton [ 1 ]`.
-}
singleElementPatternTest : (Src.Module -> Expectation) -> (() -> Expectation)
singleElementPatternTest expectFn _ =
    let
        isSingletonDef : TypedDef
        isSingletonDef =
            { name = "isSingleton"
            , args = [ pVar "xs" ]
            , tipe = tLambda (tType "List" [ tType "Int" [] ]) (tType "Bool" [])
            , body =
                caseExpr (varExpr "xs")
                    [ ( pCons (pVar "_") (pList []), boolExpr True )
                    , ( pVar "_", boolExpr False )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = callExpr (varExpr "isSingleton") [ listExpr [ intExpr 1 ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ isSingletonDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Checks with `expectFn` a program whose `sumTwo : List Int -> Int` matches
`a :: b :: []`, giving `a + b`, then a `_` variable giving `0`. `testValue` is
`sumTwo [ 3, 4 ]`.
-}
twoElementPatternTest : (Src.Module -> Expectation) -> (() -> Expectation)
twoElementPatternTest expectFn _ =
    let
        sumTwoDef : TypedDef
        sumTwoDef =
            { name = "sumTwo"
            , args = [ pVar "xs" ]
            , tipe = tLambda (tType "List" [ tType "Int" [] ]) (tType "Int" [])
            , body =
                caseExpr (varExpr "xs")
                    [ ( pCons (pVar "a") (pCons (pVar "b") (pList []))
                      , binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")
                      )
                    , ( pVar "_", intExpr 0 )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "sumTwo") [ listExpr [ intExpr 3, intExpr 4 ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ sumTwoDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Checks with `expectFn` a program whose `listLength : List Int -> Int`
matches `[]`, giving `0`, and `_ :: rest` with a `_` variable head, giving
`1 + listLength rest`. `testValue` is `listLength [ 1, 2, 3 ]`.
-}
headTailPatternTest : (Src.Module -> Expectation) -> (() -> Expectation)
headTailPatternTest expectFn _ =
    let
        listLengthDef : TypedDef
        listLengthDef =
            { name = "listLength"
            , args = [ pVar "xs" ]
            , tipe = tLambda (tType "List" [ tType "Int" [] ]) (tType "Int" [])
            , body =
                caseExpr (varExpr "xs")
                    [ ( pList [], intExpr 0 )
                    , ( pCons (pVar "_") (pVar "rest")
                      , binopsExpr
                            [ ( intExpr 1, "+" ) ]
                            (callExpr (varExpr "listLength") [ varExpr "rest" ])
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "listLength") [ listExpr [ intExpr 1, intExpr 2, intExpr 3 ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ listLengthDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Checks with `expectFn` a program whose
`flattenFirst : List (List Int) -> List Int` matches `[]`, giving `[]`, and
`first :: _` with a `_` variable tail, giving `first`. The inner lists are not
matched. `testValue` is `flattenFirst [ [ 1, 2 ], [ 3, 4 ] ]`.
-}
nestedListPatternTest : (Src.Module -> Expectation) -> (() -> Expectation)
nestedListPatternTest expectFn _ =
    let
        flattenFirstDef : TypedDef
        flattenFirstDef =
            { name = "flattenFirst"
            , args = [ pVar "xss" ]
            , tipe =
                tLambda
                    (tType "List" [ tType "List" [ tType "Int" [] ] ])
                    (tType "List" [ tType "Int" [] ])
            , body =
                caseExpr (varExpr "xss")
                    [ ( pList [], listExpr [] )
                    , ( pCons (pVar "first") (pVar "_"), varExpr "first" )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "List" [ tType "Int" [] ]
            , body =
                callExpr (varExpr "flattenFirst")
                    [ listExpr
                        [ listExpr [ intExpr 1, intExpr 2 ]
                        , listExpr [ intExpr 3, intExpr 4 ]
                        ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ flattenFirstDef, testValueDef ]
                []
                []
    in
    expectFn modul
