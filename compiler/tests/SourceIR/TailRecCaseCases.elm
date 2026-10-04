module SourceIR.TailRecCaseCases exposing (expectSuite)

{-| Programs in which a self-recursive function makes its recursive call from
inside a branch of a `case`, built so that a caller can run its own check on
each.

A tail call is a call whose result is the calling function's own result, with
nothing left to do after it. The MLIR back end compiles a function that makes a
tail call to itself to a loop rather than to a chain of calls, as
`Compiler.Generate.MLIR.TailRec` describes. When the function's body is a
`case`, each step of that loop is itself a `case`: a branch ending in the tail
call sets up the arguments of the next iteration, a branch ending in a value
finishes the loop with it, and the variables a branch's pattern binds are
extracted inside the step. That is separate code from the lowering of an
ordinary `case`, and these programs put decision trees of several shapes in
that position.

The module asserts nothing. Each program is a `Src.Module` built with
`Compiler.AST.SourceBuilder` and handed to the caller's expectation function,
which decides how far through the compiler the program goes and what is
checked. The cases run as `Compiler.BulkCheck` describes.

Four of the programs are a module named `Test`, importing `Basics` and `List`,
whose one top-level value `testValue` defines the recursive function, without
an annotation, in a `let` and applies it to arguments that include a literal
list of integers. The fifth declares its own list type and an annotated
top-level function. The function docstrings below give each program as Elm
source; the built trees have no `Parens` nodes where that source has
parentheses. In outline:

  - `tailRecFoldl`: a left fold, recursing from the `x :: xs` branch.
  - `tailRecContains`: the tail call is in the `else` of an `if` inside the
    `::` branch.
  - `tailRecCustomTypeSum`: the `case` is on the constructors `Empty` and
    `Node` of a declared type `MyList`.
  - `tailRecNestedCase`: the `::` branch is a second `case`, and the tail call
    is in that inner `case`'s wildcard branch.
  - `tailRecWildcardDestruct`: the head of the list is matched by `_`, so the
    `::` branch binds only the tail.

Among what is not tested: a tail call inside a `let` in a branch, a `case` on
literals, tuples or records, more than one tail call in a function, and mutual
recursion. Whether a program does become a loop depends on what the caller's
expectation runs, and nothing here checks it.

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
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModule
        , makeModuleWithTypedDefsUnionsAliases
        , pAnything
        , pCons
        , pCtor
        , pList
        , pVar
        , tLambda
        , tType
        , tVar
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named `"Tail-recursive case expressions "` followed by
`condStr`, that applies `expectFn` to the five programs in the order the
module docstring lists them, stopping at the first whose expectation fails and
failing under that program's label.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Tail-recursive case expressions " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns the five labelled cases, each applying `expectFn` to one program.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "Tail-rec foldl with case on list", run = tailRecFoldl expectFn }
    , { label = "Tail-rec contains with if in case branch", run = tailRecContains expectFn }
    , { label = "Tail-rec sum with custom type", run = tailRecCustomTypeSum expectFn }
    , { label = "Tail-rec with nested case", run = tailRecNestedCase expectFn }
    , { label = "Tail-rec with wildcard destruct", run = tailRecWildcardDestruct expectFn }
    ]


{-| Returns `expectFn` applied to a program whose `testValue` defines this left
fold in a `let` and applies it to `\a b -> a + b`, `0` and `[ 1, 2, 3 ]`:

    myFoldl f acc list =
        case list of
            [] ->
                acc

            x :: xs ->
                myFoldl f (f x acc) xs

-}
tailRecFoldl : (Src.Module -> Expectation) -> (() -> Expectation)
tailRecFoldl expectFn _ =
    let
        body =
            caseExpr (varExpr "list")
                [ ( pList [], varExpr "acc" )
                , ( pCons (pVar "x") (pVar "xs")
                  , callExpr (varExpr "myFoldl")
                        [ varExpr "f"
                        , callExpr (varExpr "f") [ varExpr "x", varExpr "acc" ]
                        , varExpr "xs"
                        ]
                  )
                ]

        myFoldl =
            define "myFoldl" [ pVar "f", pVar "acc", pVar "list" ] body

        modul =
            makeModule "testValue"
                (letExpr [ myFoldl ]
                    (callExpr (varExpr "myFoldl")
                        [ lambdaExpr [ pVar "a", pVar "b" ] (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b"))
                        , intExpr 0
                        , listExpr [ intExpr 1, intExpr 2, intExpr 3 ]
                        ]
                    )
                )
    in
    expectFn modul


{-| Returns `expectFn` applied to a program whose `testValue` defines this
function in a `let` and applies it to `3` and `[ 1, 2, 3 ]`. The tail call is in
the `else` of an `if`, not directly in the `case` branch:

    contains target list =
        case list of
            [] ->
                False

            x :: rest ->
                if x == target then
                    True

                else
                    contains target rest

-}
tailRecContains : (Src.Module -> Expectation) -> (() -> Expectation)
tailRecContains expectFn _ =
    let
        body =
            caseExpr (varExpr "list")
                [ ( pList [], ctorExpr "False" )
                , ( pCons (pVar "x") (pVar "rest")
                  , ifExpr
                        (binopsExpr [ ( varExpr "x", "==" ) ] (varExpr "target"))
                        (ctorExpr "True")
                        (callExpr (varExpr "contains") [ varExpr "target", varExpr "rest" ])
                  )
                ]

        containsFn =
            define "contains" [ pVar "target", pVar "list" ] body

        modul =
            makeModule "testValue"
                (letExpr [ containsFn ]
                    (callExpr (varExpr "contains") [ intExpr 3, listExpr [ intExpr 1, intExpr 2, intExpr 3 ] ])
                )
    in
    expectFn modul


{-| Returns `expectFn` applied to a module named `Test` that declares its own
list type and sums it with an annotated top-level function, so the `case` is on
the constructors of a declared type rather than on a built-in list:

    type MyList a
        = Empty
        | Node a (MyList a)

    sumMyList : Int -> MyList Int -> Int
    sumMyList acc list =
        case list of
            Empty ->
                acc

            Node x rest ->
                sumMyList (acc + x) rest

    testValue : Int
    testValue =
        sumMyList 0 (Node 1 (Node 2 Empty))

The module's imports are those `makeModuleWithTypedDefsUnionsAliases` adds.

-}
tailRecCustomTypeSum : (Src.Module -> Expectation) -> (() -> Expectation)
tailRecCustomTypeSum expectFn _ =
    let
        unions : List UnionDef
        unions =
            [ { name = "MyList"
              , args = [ "a" ]
              , ctors =
                    [ { name = "Empty", args = [] }
                    , { name = "Node", args = [ tVar "a", tType "MyList" [ tVar "a" ] ] }
                    ]
              }
            ]

        typedDefs : List TypedDef
        typedDefs =
            [ { name = "sumMyList"
              , tipe = tLambda (tType "Int" []) (tLambda (tType "MyList" [ tType "Int" [] ]) (tType "Int" []))
              , args = [ pVar "acc", pVar "list" ]
              , body =
                    caseExpr (varExpr "list")
                        [ ( pCtor "Empty" [], varExpr "acc" )
                        , ( pCtor "Node" [ pVar "x", pVar "rest" ]
                          , callExpr (varExpr "sumMyList")
                                [ binopsExpr [ ( varExpr "acc", "+" ) ] (varExpr "x")
                                , varExpr "rest"
                                ]
                          )
                        ]
              }
            ]

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "sumMyList")
                    [ intExpr 0
                    , callExpr (ctorExpr "Node")
                        [ intExpr 1
                        , callExpr (ctorExpr "Node")
                            [ intExpr 2
                            , ctorExpr "Empty"
                            ]
                        ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                (typedDefs ++ [ testValueDef ])
                unions
                []
    in
    expectFn modul


{-| Returns `expectFn` applied to a program whose `testValue` defines this
function in a `let` and applies it to `0` and `[ 1, 2, 3 ]`. The `::` branch is
a second `case`, and the tail call is in its wildcard branch:

    myLast default list =
        case list of
            [] ->
                default

            x :: rest ->
                case rest of
                    [] ->
                        x

                    _ ->
                        myLast default rest

-}
tailRecNestedCase : (Src.Module -> Expectation) -> (() -> Expectation)
tailRecNestedCase expectFn _ =
    let
        body =
            caseExpr (varExpr "list")
                [ ( pList [], varExpr "default" )
                , ( pCons (pVar "x") (pVar "rest")
                  , caseExpr (varExpr "rest")
                        [ ( pList [], varExpr "x" )
                        , ( pAnything
                          , callExpr (varExpr "myLast") [ varExpr "default", varExpr "rest" ]
                          )
                        ]
                  )
                ]

        myLast =
            define "myLast" [ pVar "default", pVar "list" ] body

        modul =
            makeModule "testValue"
                (letExpr [ myLast ]
                    (callExpr (varExpr "myLast") [ intExpr 0, listExpr [ intExpr 1, intExpr 2, intExpr 3 ] ])
                )
    in
    expectFn modul


{-| Returns `expectFn` applied to a program whose `testValue` defines this
function in a `let` and applies it to `0` and `[ 10, 20, 30 ]`. The head is
matched by `_`, so the `::` branch binds only `rest`:

    count acc list =
        case list of
            [] ->
                acc

            _ :: rest ->
                count (acc + 1) rest

-}
tailRecWildcardDestruct : (Src.Module -> Expectation) -> (() -> Expectation)
tailRecWildcardDestruct expectFn _ =
    let
        body =
            caseExpr (varExpr "list")
                [ ( pList [], varExpr "acc" )
                , ( pCons pAnything (pVar "rest")
                  , callExpr (varExpr "count")
                        [ binopsExpr [ ( varExpr "acc", "+" ) ] (intExpr 1)
                        , varExpr "rest"
                        ]
                  )
                ]

        countFn =
            define "count" [ pVar "acc", pVar "list" ] body

        modul =
            makeModule "testValue"
                (letExpr [ countFn ]
                    (callExpr (varExpr "count") [ intExpr 0, listExpr [ intExpr 10, intExpr 20, intExpr 30 ] ])
                )
    in
    expectFn modul
