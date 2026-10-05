module SourceIR.TailRecLetRecClosureCases exposing (expectSuite)

{-| Source programs in which a tail-recursive function defines, in a `let`
inside one of its branches, a local function that calls itself.

A function that calls itself in tail position is compiled by the MLIR back end
as a loop (`Compiler.Generate.MLIR.TailRec`), and a `let` met in the loop body
goes through that module's own let step, which sets up the names the `let`
binds before each definition is compiled. A local function defined there must
be able to refer to its own name from inside its body. This module builds
programs of that shape and asserts nothing itself: what is checked is decided
by the expectation function the caller passes to `expectSuite`.

Each case builds a module named `Test` with
`makeModuleWithTypedDefsUnionsAliases`. It holds an annotated two-argument
function whose `case` has a branch returning `[]`, a branch defining the local
function in a `let`, and a branch that is the tail call; and a `testValue` that
calls it on a list whose first element takes the tail call, so the loop runs at
least twice. In both cases the local function's self-call is not in tail
position (it is the right operand of `::`). The programs are given as Elm
source in each case's docstring.

What the cases are:

  - "Local recursive closure in tail-rec case branch" (`tailRecWithLocalRecClosure`)
    declares `type Item = Num Int | Blank`. The local function `takeMore`
    collects the `Int`s from the leading `Num`s of a list, and its result is
    bound to a second `let` name before use. It refers to nothing from the
    enclosing function, whose first parameter, `threshold`, is only passed on
    unchanged in the tail call.
  - "Local recursive closure capturing outer param" (`tailRecWithCapturingClosure`)
    works on `List Int`. Its local function `helper` adds the enclosing
    function's parameter `threshold` to each element, so it captures it.

Among what is not tested: a local function that is itself tail-recursive, and
local functions that call each other.

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
        , pCons
        , pCtor
        , pInt
        , pList
        , pVar
        , tLambda
        , tType
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Tail-rec with local recursive closure " followed by
`condStr`, that gives each case's module to `expectFn` in turn, stopping at the
first case that fails. The cases are run with `Compiler.BulkCheck.bulkCheck`,
and the test reports that failure under the case's label.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Tail-rec with local recursive closure " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns the two labelled cases, each giving its own module to `expectFn`.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "Local recursive closure in tail-rec case branch", run = tailRecWithLocalRecClosure expectFn }
    , { label = "Local recursive closure capturing outer param", run = tailRecWithCapturingClosure expectFn }
    ]


{-| Runs `expectFn` on a module holding this program, written here as Elm
source:

    type Item
        = Num Int
        | Blank

    processItems : Int -> List Item -> List Int
    processItems threshold items =
        case items of
            [] ->
                []

            (Num n) :: rest ->
                let
                    takeMore xs =
                        case xs of
                            (Num m) :: ys ->
                                m :: takeMore ys

                            _ ->
                                []

                    collected =
                        takeMore rest
                in
                n :: collected

            Blank :: rest ->
                processItems threshold rest

    testValue : List Int
    testValue =
        processItems 0 [ Blank, Num 1, Num 2, Blank ]

The tail call is in the `Blank` branch, which the first element takes;
`takeMore` is defined in the `Num` branch, which ends the loop.

-}
tailRecWithLocalRecClosure : (Src.Module -> Expectation) -> (() -> Expectation)
tailRecWithLocalRecClosure expectFn _ =
    let
        unions : List UnionDef
        unions =
            [ { name = "Item"
              , args = []
              , ctors =
                    [ { name = "Num", args = [ tType "Int" [] ] }
                    , { name = "Blank", args = [] }
                    ]
              }
            ]

        takeMoreBody =
            caseExpr (varExpr "xs")
                [ ( pCons (pCtor "Num" [ pVar "m" ]) (pVar "ys")
                  , binopsExpr
                        [ ( varExpr "m", "::" ) ]
                        (callExpr (varExpr "takeMore") [ varExpr "ys" ])
                  )
                , ( pAnything, listExpr [] )
                ]

        takeMoreDef =
            define "takeMore" [ pVar "xs" ] takeMoreBody

        collectedDef =
            define "collected" [] (callExpr (varExpr "takeMore") [ varExpr "rest" ])

        processItemsBody =
            caseExpr (varExpr "items")
                [ ( pList [], listExpr [] )
                , ( pCons (pCtor "Num" [ pVar "n" ]) (pVar "rest")
                  , letExpr [ takeMoreDef, collectedDef ]
                        (binopsExpr [ ( varExpr "n", "::" ) ] (varExpr "collected"))
                  )
                , ( pCons (pCtor "Blank" []) (pVar "rest")
                  , callExpr (varExpr "processItems") [ varExpr "threshold", varExpr "rest" ]
                  )
                ]

        typedDefs : List TypedDef
        typedDefs =
            [ { name = "processItems"
              , tipe =
                    tLambda (tType "Int" [])
                        (tLambda (tType "List" [ tType "Item" [] ])
                            (tType "List" [ tType "Int" [] ])
                        )
              , args = [ pVar "threshold", pVar "items" ]
              , body = processItemsBody
              }
            ]

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "List" [ tType "Int" [] ]
            , body =
                callExpr (varExpr "processItems")
                    [ intExpr 0
                    , listExpr
                        [ ctorExpr "Blank"
                        , callExpr (ctorExpr "Num") [ intExpr 1 ]
                        , callExpr (ctorExpr "Num") [ intExpr 2 ]
                        , ctorExpr "Blank"
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


{-| Runs `expectFn` on a module holding this program, written here as Elm
source:

    process : Int -> List Int -> List Int
    process threshold items =
        case items of
            [] ->
                []

            0 :: rest ->
                process threshold rest

            x :: rest ->
                let
                    helper ys =
                        case ys of
                            y :: zs ->
                                (y + threshold) :: helper zs

                            _ ->
                                []
                in
                x :: helper rest

    testValue : List Int
    testValue =
        process 10 [ 0, 1, 2, 3 ]

`helper` captures `threshold`, a parameter of the loop function `process`. The
first element, 0, takes the tail call, and the second ends the loop.

-}
tailRecWithCapturingClosure : (Src.Module -> Expectation) -> (() -> Expectation)
tailRecWithCapturingClosure expectFn _ =
    let
        helperBody =
            caseExpr (varExpr "ys")
                [ ( pCons (pVar "y") (pVar "zs")
                  , binopsExpr
                        [ ( binopsExpr [ ( varExpr "y", "+" ) ] (varExpr "threshold"), "::" ) ]
                        (callExpr (varExpr "helper") [ varExpr "zs" ])
                  )
                , ( pAnything, listExpr [] )
                ]

        helperDef =
            define "helper" [ pVar "ys" ] helperBody

        processBody =
            caseExpr (varExpr "items")
                [ ( pList [], listExpr [] )
                , ( pCons (pInt 0) (pVar "rest")
                  , callExpr (varExpr "process") [ varExpr "threshold", varExpr "rest" ]
                  )
                , ( pCons (pVar "x") (pVar "rest")
                  , letExpr [ helperDef ]
                        (binopsExpr
                            [ ( varExpr "x", "::" ) ]
                            (callExpr (varExpr "helper") [ varExpr "rest" ])
                        )
                  )
                ]

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ { name = "process"
                  , tipe =
                        tLambda (tType "Int" [])
                            (tLambda (tType "List" [ tType "Int" [] ])
                                (tType "List" [ tType "Int" [] ])
                            )
                  , args = [ pVar "threshold", pVar "items" ]
                  , body = processBody
                  }
                , { name = "testValue"
                  , args = []
                  , tipe = tType "List" [ tType "Int" [] ]
                  , body =
                        callExpr (varExpr "process")
                            [ intExpr 10
                            , listExpr [ intExpr 0, intExpr 1, intExpr 2, intExpr 3 ]
                            ]
                  }
                ]
                []
                []
    in
    expectFn modul
