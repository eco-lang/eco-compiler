module SourceIR.SpecializePolyTopCases exposing (expectSuite)

{-| Programs in which `testValue` uses an annotated, polymorphic top-level
function twice, in all but one case at two different types, for checking what a
compiler stage does with such a function.

Monomorphization makes a separate copy of a polymorphic function, a
_specialization_, for each type the function is used at. A program that
uses each function at one type only never needs more than one specialization of
it, so an error in keeping two specializations of one function apart would go
unnoticed there. These cases supply the programs; this module checks nothing
itself. `expectSuite` runs the expectation function it is given on the cases in
turn, stopping at the first that fails, and that function decides what is
checked.

Every case builds a module named `Test` with
`Compiler.AST.SourceBuilder.makeModuleWithTypedDefs`, so every top-level
definition carries a type annotation. Each module has a `testValue` whose
annotation is a pair type and whose body is a pair of two uses of the
polymorphic function (in one case, two `let` definitions partially apply it and
the pair calls those). Five cases also define `addOne : Int -> Int`, to pass as
a function argument.

An integer literal has type `number` until something fixes it; here the
annotations of `testValue` and `addOne` fix most of them to `Int`, but in two
places they stay `number`: the `1` in `const "hi" 1`, and both elements of
`length [ 1, 2 ]`.

The cases, in the order they run, by label:

  - "identity at Int and String": `identity : a -> a` at `Int` and `String`.
  - "const at two type combos": `const : a -> b -> a` with its arguments of
    types `Int`, `String` and then `String`, `number`.
  - "apply higher-order at two types": `apply : (a -> b) -> a -> b` with
    `a` and `b` both `Int`, then both `String`.
  - "compose at two type combos": `compose : (b -> c) -> (a -> b) -> a -> c`
    called once with every type `Int` and once with every type `String`.
  - "recursive length at two list types": a non-tail-recursive
    `length : List a -> Int` on a list of integer literals and a list of
    strings.
  - "tail-recursive foldl at two types": a self-tail-recursive
    `foldl : (a -> b -> b) -> b -> List a -> b` with `a` `Int`, then `String`,
    and `b` `Int` both times.
  - "recursive map at two types": a non-tail-recursive
    `map : (a -> b) -> List a -> List b` at `Int` and at `String`.
  - "partial application of map": the same `map`, partially applied in two
    `let` definitions inside `testValue`, at `Int` and at `String`.
  - "pair constructor at two type combos": `pair : a -> b -> ( a, b )`, a
    function rather than a constructor, at `Int`, `String` and at `String`,
    `Int`.
  - "tail-recursive reverse at two types": `reverse : List a -> List a`, which
    is not itself recursive and calls the self-tail-recursive `reverseHelper`,
    at `List Int` and `List String`.
  - "twice higher-order at two types": `twice : (a -> a) -> a -> a` at `Int`
    and `String`.
  - "singleton at two types": `singleton : a -> List a` at `Int` and `String`.

Among what is not tested:

  - A function used at three or more types.
  - A polymorphic top-level function passed as a value: each one is only ever
    called, though `map` is called with too few arguments in one case.
  - Records, custom types declared in the program, or a constrained type
    variable such as `number` in an annotation.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , binopsExpr
        , callExpr
        , caseExpr
        , define
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModuleWithTypedDefs
        , pAnything
        , pCons
        , pList
        , pVar
        , strExpr
        , tLambda
        , tTuple
        , tType
        , tVar
        , tupleExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Poly top-level multi-specialization " followed by
`condStr`, that runs `expectFn` on each case's module in turn with
`Compiler.BulkCheck.bulkCheck`. As `bulkCheck` describes, the test fails with
the label of the first failing case, and the cases after it do not run.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Poly top-level multi-specialization " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns the twelve cases, each a label paired with a check that runs
`expectFn` on that case's module.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "identity at Int and String", run = identityMulti expectFn }
    , { label = "const at two type combos", run = constMulti expectFn }
    , { label = "apply higher-order at two types", run = applyMulti expectFn }
    , { label = "compose at two type combos", run = composeMulti expectFn }
    , { label = "recursive length at two list types", run = lengthMulti expectFn }
    , { label = "tail-recursive foldl at two types", run = foldlMulti expectFn }
    , { label = "recursive map at two types", run = mapMulti expectFn }
    , { label = "partial application of map", run = mapPartialMulti expectFn }
    , { label = "pair constructor at two type combos", run = pairMulti expectFn }
    , { label = "tail-recursive reverse at two types", run = reverseMulti expectFn }
    , { label = "twice higher-order at two types", run = twiceMulti expectFn }
    , { label = "singleton at two types", run = singletonMulti expectFn }
    ]


{-| Runs `expectFn` on a program that applies one identity function to an
`Int` and to a `String`. In Elm source:

    identity : a -> a
    identity x =
        x

    testValue : ( Int, String )
    testValue =
        ( identity 1, identity "hello" )

-}
identityMulti : (Src.Module -> Expectation) -> (() -> Expectation)
identityMulti expectFn _ =
    let
        identityDef : TypedDef
        identityDef =
            { name = "identity"
            , args = [ pVar "x" ]
            , tipe = tLambda (tVar "a") (tVar "a")
            , body = varExpr "x"
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tTuple (tType "Int" []) (tType "String" [])
            , body =
                tupleExpr
                    (callExpr (varExpr "identity") [ intExpr 1 ])
                    (callExpr (varExpr "identity") [ strExpr "hello" ])
            }

        modul =
            makeModuleWithTypedDefs "Test" [ identityDef, testValueDef ]
    in
    expectFn modul


{-| Runs `expectFn` on a program that uses `const` with its two arguments in
both orders. In Elm source:

    const : a -> b -> a
    const a b =
        a

    testValue : ( Int, String )
    testValue =
        ( const 1 "hi", const "hi" 1 )

The annotation fixes the first `1` to `Int`. The second `1` is the discarded
argument, so nothing fixes it and its type stays `number`.

-}
constMulti : (Src.Module -> Expectation) -> (() -> Expectation)
constMulti expectFn _ =
    let
        constDef : TypedDef
        constDef =
            { name = "const"
            , args = [ pVar "a", pVar "b" ]
            , tipe = tLambda (tVar "a") (tLambda (tVar "b") (tVar "a"))
            , body = varExpr "a"
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tTuple (tType "Int" []) (tType "String" [])
            , body =
                tupleExpr
                    (callExpr (varExpr "const") [ intExpr 1, strExpr "hi" ])
                    (callExpr (varExpr "const") [ strExpr "hi", intExpr 1 ])
            }

        modul =
            makeModuleWithTypedDefs "Test" [ constDef, testValueDef ]
    in
    expectFn modul


{-| Runs `expectFn` on a program that uses `apply` once with `addOne` on an
`Int` and once with an identity lambda on a `String`. In Elm source:

    apply : (a -> b) -> a -> b
    apply f x =
        f x

    addOne : Int -> Int
    addOne n =
        n + 1

    testValue : ( Int, String )
    testValue =
        ( apply addOne 1, apply (\s -> s) "hi" )

-}
applyMulti : (Src.Module -> Expectation) -> (() -> Expectation)
applyMulti expectFn _ =
    let
        applyDef : TypedDef
        applyDef =
            { name = "apply"
            , args = [ pVar "f", pVar "x" ]
            , tipe =
                tLambda (tLambda (tVar "a") (tVar "b"))
                    (tLambda (tVar "a") (tVar "b"))
            , body = callExpr (varExpr "f") [ varExpr "x" ]
            }

        addOneDef : TypedDef
        addOneDef =
            { name = "addOne"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body = binopsExpr [ ( varExpr "n", "+" ) ] (intExpr 1)
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tTuple (tType "Int" []) (tType "String" [])
            , body =
                tupleExpr
                    (callExpr (varExpr "apply") [ varExpr "addOne", intExpr 1 ])
                    (callExpr (varExpr "apply")
                        [ lambdaExpr [ pVar "s" ] (varExpr "s")
                        , strExpr "hi"
                        ]
                    )
            }

        modul =
            makeModuleWithTypedDefs "Test"
                [ applyDef, addOneDef, testValueDef ]
    in
    expectFn modul


{-| Runs `expectFn` on a program that calls `compose` twice, once with every type
variable `Int` and once with every type variable `String`. In Elm source:

    compose : (b -> c) -> (a -> b) -> a -> c
    compose f g x =
        f (g x)

    addOne : Int -> Int
    addOne n =
        n + 1

    exclaim : String -> String
    exclaim s =
        s ++ "!"

    testValue : ( Int, String )
    testValue =
        ( compose addOne addOne 1, compose exclaim exclaim "hi" )

-}
composeMulti : (Src.Module -> Expectation) -> (() -> Expectation)
composeMulti expectFn _ =
    let
        composeDef : TypedDef
        composeDef =
            { name = "compose"
            , args = [ pVar "f", pVar "g", pVar "x" ]
            , tipe =
                tLambda (tLambda (tVar "b") (tVar "c"))
                    (tLambda (tLambda (tVar "a") (tVar "b"))
                        (tLambda (tVar "a") (tVar "c"))
                    )
            , body = callExpr (varExpr "f") [ callExpr (varExpr "g") [ varExpr "x" ] ]
            }

        addOneDef : TypedDef
        addOneDef =
            { name = "addOne"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body = binopsExpr [ ( varExpr "n", "+" ) ] (intExpr 1)
            }

        exclaimDef : TypedDef
        exclaimDef =
            { name = "exclaim"
            , args = [ pVar "s" ]
            , tipe = tLambda (tType "String" []) (tType "String" [])
            , body = binopsExpr [ ( varExpr "s", "++" ) ] (strExpr "!")
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tTuple (tType "Int" []) (tType "String" [])
            , body =
                tupleExpr
                    (callExpr (varExpr "compose")
                        [ varExpr "addOne", varExpr "addOne", intExpr 1 ]
                    )
                    (callExpr (varExpr "compose")
                        [ varExpr "exclaim", varExpr "exclaim", strExpr "hi" ]
                    )
            }

        modul =
            makeModuleWithTypedDefs "Test"
                [ composeDef, addOneDef, exclaimDef, testValueDef ]
    in
    expectFn modul


{-| Runs `expectFn` on a program that applies a recursive `length` to a list
of integer literals and to a list of strings. In Elm source:

    length : List a -> Int
    length xs =
        case xs of
            [] ->
                0

            _ :: rest ->
                1 + length rest

    testValue : ( Int, Int )
    testValue =
        ( length [ 1, 2 ], length [ "a", "b" ] )

The recursive call is an operand of `+`, so `length` is not tail-recursive.
Nothing fixes the type of the integer literals, so the first list is a
`List number`, not a `List Int`.

-}
lengthMulti : (Src.Module -> Expectation) -> (() -> Expectation)
lengthMulti expectFn _ =
    let
        lengthDef : TypedDef
        lengthDef =
            { name = "length"
            , args = [ pVar "xs" ]
            , tipe =
                tLambda (tType "List" [ tVar "a" ]) (tType "Int" [])
            , body =
                caseExpr (varExpr "xs")
                    [ ( pList [], intExpr 0 )
                    , ( pCons pAnything (pVar "rest")
                      , binopsExpr
                            [ ( intExpr 1, "+" ) ]
                            (callExpr (varExpr "length") [ varExpr "rest" ])
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tTuple (tType "Int" []) (tType "Int" [])
            , body =
                tupleExpr
                    (callExpr (varExpr "length") [ listExpr [ intExpr 1, intExpr 2 ] ])
                    (callExpr (varExpr "length") [ listExpr [ strExpr "a", strExpr "b" ] ])
            }

        modul =
            makeModuleWithTypedDefs "Test" [ lengthDef, testValueDef ]
    in
    expectFn modul


{-| Runs `expectFn` on a program that uses a self-tail-recursive `foldl` once
to sum a list of integers and once to count a list of strings. In Elm source:

    foldl : (a -> b -> b) -> b -> List a -> b
    foldl f acc xs =
        case xs of
            [] ->
                acc

            x :: rest ->
                foldl f (f x acc) rest

    testValue : ( Int, Int )
    testValue =
        ( foldl (\x acc -> x + acc) 0 [ 1, 2, 3 ]
        , foldl (\x acc -> acc + 1) 0 [ "a", "b" ]
        )

-}
foldlMulti : (Src.Module -> Expectation) -> (() -> Expectation)
foldlMulti expectFn _ =
    let
        foldlDef : TypedDef
        foldlDef =
            { name = "foldl"
            , args = [ pVar "f", pVar "acc", pVar "xs" ]
            , tipe =
                tLambda (tLambda (tVar "a") (tLambda (tVar "b") (tVar "b")))
                    (tLambda (tVar "b")
                        (tLambda (tType "List" [ tVar "a" ]) (tVar "b"))
                    )
            , body =
                caseExpr (varExpr "xs")
                    [ ( pList [], varExpr "acc" )
                    , ( pCons (pVar "x") (pVar "rest")
                      , callExpr (varExpr "foldl")
                            [ varExpr "f"
                            , callExpr (varExpr "f") [ varExpr "x", varExpr "acc" ]
                            , varExpr "rest"
                            ]
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tTuple (tType "Int" []) (tType "Int" [])
            , body =
                tupleExpr
                    (callExpr (varExpr "foldl")
                        [ lambdaExpr [ pVar "x", pVar "acc" ]
                            (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "acc"))
                        , intExpr 0
                        , listExpr [ intExpr 1, intExpr 2, intExpr 3 ]
                        ]
                    )
                    (callExpr (varExpr "foldl")
                        [ lambdaExpr [ pVar "x", pVar "acc" ]
                            (binopsExpr [ ( varExpr "acc", "+" ) ] (intExpr 1))
                        , intExpr 0
                        , listExpr [ strExpr "a", strExpr "b" ]
                        ]
                    )
            }

        modul =
            makeModuleWithTypedDefs "Test" [ foldlDef, testValueDef ]
    in
    expectFn modul


{-| Runs `expectFn` on a program that uses a recursive `map` once with
`addOne` on a list of `Int` and once with an identity lambda on a list of
`String`. In Elm source:

    map : (a -> b) -> List a -> List b
    map f xs =
        case xs of
            [] ->
                []

            x :: rest ->
                f x :: map f rest

    addOne : Int -> Int
    addOne n =
        n + 1

    testValue : ( List Int, List String )
    testValue =
        ( map addOne [ 1, 2 ], map (\s -> s) [ "a", "b" ] )

The recursive call is an operand of `::`, so `map` is not tail-recursive.

-}
mapMulti : (Src.Module -> Expectation) -> (() -> Expectation)
mapMulti expectFn _ =
    let
        mapDef : TypedDef
        mapDef =
            { name = "map"
            , args = [ pVar "f", pVar "xs" ]
            , tipe =
                tLambda (tLambda (tVar "a") (tVar "b"))
                    (tLambda (tType "List" [ tVar "a" ]) (tType "List" [ tVar "b" ]))
            , body =
                caseExpr (varExpr "xs")
                    [ ( pList [], listExpr [] )
                    , ( pCons (pVar "x") (pVar "rest")
                      , binopsExpr
                            [ ( callExpr (varExpr "f") [ varExpr "x" ], "::" ) ]
                            (callExpr (varExpr "map") [ varExpr "f", varExpr "rest" ])
                      )
                    ]
            }

        addOneDef : TypedDef
        addOneDef =
            { name = "addOne"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body = binopsExpr [ ( varExpr "n", "+" ) ] (intExpr 1)
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe =
                tTuple
                    (tType "List" [ tType "Int" [] ])
                    (tType "List" [ tType "String" [] ])
            , body =
                tupleExpr
                    (callExpr (varExpr "map") [ varExpr "addOne", listExpr [ intExpr 1, intExpr 2 ] ])
                    (callExpr (varExpr "map")
                        [ lambdaExpr [ pVar "s" ] (varExpr "s")
                        , listExpr [ strExpr "a", strExpr "b" ]
                        ]
                    )
            }

        modul =
            makeModuleWithTypedDefs "Test" [ mapDef, addOneDef, testValueDef ]
    in
    expectFn modul


{-| Runs `expectFn` on a program that partially applies `map`, binding each
partial application to a name in a `let` and then applying it to a list. In Elm
source, with `map` and `addOne` defined as in `mapMulti`:

    testValue : ( List Int, List String )
    testValue =
        let
            mapAddOne =
                map addOne

            mapId =
                map (\s -> s)
        in
        ( mapAddOne [ 1, 2 ], mapId [ "a", "b" ] )

-}
mapPartialMulti : (Src.Module -> Expectation) -> (() -> Expectation)
mapPartialMulti expectFn _ =
    let
        mapDef : TypedDef
        mapDef =
            { name = "map"
            , args = [ pVar "f", pVar "xs" ]
            , tipe =
                tLambda (tLambda (tVar "a") (tVar "b"))
                    (tLambda (tType "List" [ tVar "a" ]) (tType "List" [ tVar "b" ]))
            , body =
                caseExpr (varExpr "xs")
                    [ ( pList [], listExpr [] )
                    , ( pCons (pVar "x") (pVar "rest")
                      , binopsExpr
                            [ ( callExpr (varExpr "f") [ varExpr "x" ], "::" ) ]
                            (callExpr (varExpr "map") [ varExpr "f", varExpr "rest" ])
                      )
                    ]
            }

        addOneDef : TypedDef
        addOneDef =
            { name = "addOne"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body = binopsExpr [ ( varExpr "n", "+" ) ] (intExpr 1)
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe =
                tTuple
                    (tType "List" [ tType "Int" [] ])
                    (tType "List" [ tType "String" [] ])
            , body =
                letExpr
                    [ define "mapAddOne"
                        []
                        (callExpr (varExpr "map") [ varExpr "addOne" ])
                    , define "mapId"
                        []
                        (callExpr (varExpr "map")
                            [ lambdaExpr [ pVar "s" ] (varExpr "s") ]
                        )
                    ]
                    (tupleExpr
                        (callExpr (varExpr "mapAddOne") [ listExpr [ intExpr 1, intExpr 2 ] ])
                        (callExpr (varExpr "mapId") [ listExpr [ strExpr "a", strExpr "b" ] ])
                    )
            }

        modul =
            makeModuleWithTypedDefs "Test" [ mapDef, addOneDef, testValueDef ]
    in
    expectFn modul


{-| Runs `expectFn` on a program that uses `pair` with its two arguments in
both orders. In Elm source:

    pair : a -> b -> ( a, b )
    pair a b =
        ( a, b )

    testValue : ( ( Int, String ), ( String, Int ) )
    testValue =
        ( pair 1 "hi", pair "hi" 1 )

-}
pairMulti : (Src.Module -> Expectation) -> (() -> Expectation)
pairMulti expectFn _ =
    let
        pairDef : TypedDef
        pairDef =
            { name = "pair"
            , args = [ pVar "a", pVar "b" ]
            , tipe =
                tLambda (tVar "a")
                    (tLambda (tVar "b") (tTuple (tVar "a") (tVar "b")))
            , body = tupleExpr (varExpr "a") (varExpr "b")
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe =
                tTuple
                    (tTuple (tType "Int" []) (tType "String" []))
                    (tTuple (tType "String" []) (tType "Int" []))
            , body =
                tupleExpr
                    (callExpr (varExpr "pair") [ intExpr 1, strExpr "hi" ])
                    (callExpr (varExpr "pair") [ strExpr "hi", intExpr 1 ])
            }

        modul =
            makeModuleWithTypedDefs "Test" [ pairDef, testValueDef ]
    in
    expectFn modul


{-| Runs `expectFn` on a program that reverses a list of `Int` and a list of
`String` with a `reverse` that hands the work to a self-tail-recursive helper.
In Elm source:

    reverseHelper : List a -> List a -> List a
    reverseHelper acc xs =
        case xs of
            [] ->
                acc

            x :: rest ->
                reverseHelper (x :: acc) rest

    reverse : List a -> List a
    reverse xs =
        reverseHelper [] xs

    testValue : ( List Int, List String )
    testValue =
        ( reverse [ 1, 2 ], reverse [ "a", "b" ] )

`testValue` never names `reverseHelper`, which is used only in its own
recursive call and inside `reverse`.

-}
reverseMulti : (Src.Module -> Expectation) -> (() -> Expectation)
reverseMulti expectFn _ =
    let
        reverseHelperDef : TypedDef
        reverseHelperDef =
            { name = "reverseHelper"
            , args = [ pVar "acc", pVar "xs" ]
            , tipe =
                tLambda (tType "List" [ tVar "a" ])
                    (tLambda (tType "List" [ tVar "a" ]) (tType "List" [ tVar "a" ]))
            , body =
                caseExpr (varExpr "xs")
                    [ ( pList [], varExpr "acc" )
                    , ( pCons (pVar "x") (pVar "rest")
                      , callExpr (varExpr "reverseHelper")
                            [ binopsExpr [ ( varExpr "x", "::" ) ] (varExpr "acc")
                            , varExpr "rest"
                            ]
                      )
                    ]
            }

        reverseDef : TypedDef
        reverseDef =
            { name = "reverse"
            , args = [ pVar "xs" ]
            , tipe =
                tLambda (tType "List" [ tVar "a" ]) (tType "List" [ tVar "a" ])
            , body =
                callExpr (varExpr "reverseHelper") [ listExpr [], varExpr "xs" ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe =
                tTuple
                    (tType "List" [ tType "Int" [] ])
                    (tType "List" [ tType "String" [] ])
            , body =
                tupleExpr
                    (callExpr (varExpr "reverse") [ listExpr [ intExpr 1, intExpr 2 ] ])
                    (callExpr (varExpr "reverse") [ listExpr [ strExpr "a", strExpr "b" ] ])
            }

        modul =
            makeModuleWithTypedDefs "Test"
                [ reverseHelperDef, reverseDef, testValueDef ]
    in
    expectFn modul


{-| Runs `expectFn` on a program that uses `twice` once with `addOne` on an
`Int` and once with an identity lambda on a `String`. In Elm source:

    twice : (a -> a) -> a -> a
    twice f x =
        f (f x)

    addOne : Int -> Int
    addOne n =
        n + 1

    testValue : ( Int, String )
    testValue =
        ( twice addOne 0, twice (\s -> s) "hi" )

-}
twiceMulti : (Src.Module -> Expectation) -> (() -> Expectation)
twiceMulti expectFn _ =
    let
        twiceDef : TypedDef
        twiceDef =
            { name = "twice"
            , args = [ pVar "f", pVar "x" ]
            , tipe =
                tLambda (tLambda (tVar "a") (tVar "a"))
                    (tLambda (tVar "a") (tVar "a"))
            , body =
                callExpr (varExpr "f")
                    [ callExpr (varExpr "f") [ varExpr "x" ] ]
            }

        addOneDef : TypedDef
        addOneDef =
            { name = "addOne"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body = binopsExpr [ ( varExpr "n", "+" ) ] (intExpr 1)
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tTuple (tType "Int" []) (tType "String" [])
            , body =
                tupleExpr
                    (callExpr (varExpr "twice") [ varExpr "addOne", intExpr 0 ])
                    (callExpr (varExpr "twice")
                        [ lambdaExpr [ pVar "s" ] (varExpr "s")
                        , strExpr "hi"
                        ]
                    )
            }

        modul =
            makeModuleWithTypedDefs "Test"
                [ twiceDef, addOneDef, testValueDef ]
    in
    expectFn modul


{-| Runs `expectFn` on a program that makes a one-element list of an `Int` and
of a `String`. In Elm source:

    singleton : a -> List a
    singleton x =
        [ x ]

    testValue : ( List Int, List String )
    testValue =
        ( singleton 42, singleton "hi" )

-}
singletonMulti : (Src.Module -> Expectation) -> (() -> Expectation)
singletonMulti expectFn _ =
    let
        singletonDef : TypedDef
        singletonDef =
            { name = "singleton"
            , args = [ pVar "x" ]
            , tipe = tLambda (tVar "a") (tType "List" [ tVar "a" ])
            , body = listExpr [ varExpr "x" ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe =
                tTuple
                    (tType "List" [ tType "Int" [] ])
                    (tType "List" [ tType "String" [] ])
            , body =
                tupleExpr
                    (callExpr (varExpr "singleton") [ intExpr 42 ])
                    (callExpr (varExpr "singleton") [ strExpr "hi" ])
            }

        modul =
            makeModuleWithTypedDefs "Test" [ singletonDef, testValueDef ]
    in
    expectFn modul
