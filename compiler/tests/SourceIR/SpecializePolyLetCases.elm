module SourceIR.SpecializePolyLetCases exposing (expectSuite)

{-| Supplies programs built around polymorphic functions defined in a `let`,
most of them used at more than one type.

Elm generalises a function defined in a `let`, so in
`let identity x = x in ( identity 1, identity "hello" )` the one local
`identity` is used at a number and at a `String`. Monomorphization makes
copies of a polymorphic function at the concrete types it is used at, called
specialisations. All but two of these programs ask for more than one
specialisation of a function that is local rather than top-level.

The module checks nothing itself. `expectSuite` passes each program to the
expectation function it is given, and that function decides which stage runs
and what is checked.

Every program is a module named `Test`, built with `makeModule`, so it imports
only `Basics` and `List`. Its one top-level value, `testValue`, is a `let`
around a body. Neither `testValue` nor any local definition has an annotation,
so every type comes from inference. No annotation fixes `Int` either, so an
integer literal has type `number` and `+` is
`number -> number -> number`; "a number" below means such a value. Each case,
by its label:

  - "identity at Int and String": `identity` at a number and a `String`.
  - "const at two type combos": `const` at (number, `String`) and
    (`String`, number).
  - "apply higher-order at two types": `apply` with a function on numbers and
    a function on `String`s.
  - "compose at two type combos": `compose` and `addOne`, but both uses of
    `compose` apply it to `addOne`, `addOne` and a number, never to a
    `String`.
  - "recursive length at two list types": a `length` that is not
    tail-recursive, on a list of numbers and a list of `String`s.
  - "tail-recursive foldl at two types": `foldl` over a list of numbers and a
    list of `String`s, with a number as the accumulator both times.
  - "recursive map at two types": a `map` that is not tail-recursive, over
    numbers and over `String`s.
  - "partial application of map": the same `map`, used only through two
    partial applications defined without arguments, one at numbers and one
    at `String`s.
  - "pair constructor at two type combos": a function `pair` building a
    tuple (not a constructor) at (number, `String`) and (`String`, number).
  - "tail-recursive reverse at two types": `reverse` on a list of numbers and
    a list of `String`s, through a tail-recursive local `reverseHelper`.
  - "twice higher-order at two types": `twice` with a function on numbers and
    a function on `String`s.
  - "singleton at two types": `singleton` at a number and a `String`.
  - "named local as higher-order arg": a local `identity` passed by name to a
    local `apply`, at one type only.
  - "named local as higher-order arg at two types": the same, at a number and
    at a `String`.

Except in "named local as higher-order arg", `testValue` is a pair whose two
halves are the two uses, so both uses are reachable from it.

Among what is not tested:

  - a local function with a type annotation;
  - a local function that refers to a variable bound outside its own `let`;
  - mutually recursive local functions;
  - a local function defined inside another local function's body;
  - a local function used at `Float`, `Char`, a record or a custom type.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , callExpr
        , caseExpr
        , define
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModule
        , pAnything
        , pCons
        , pList
        , pVar
        , strExpr
        , tupleExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Poly let-bound multi-specialization " followed by
`condStr`, that passes this module's programs to `expectFn` one at a time in
the order `testCases` lists them, and stops at the first whose expectation
fails. That failure is reported under the case's label, as
`Compiler.BulkCheck.bulkCheck` describes.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Poly let-bound multi-specialization " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns the fourteen cases, each a label paired with a check that builds
its program and passes it to `expectFn`.
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
    , { label = "named local as higher-order arg", run = namedLocalAsArg expectFn }
    , { label = "named local as higher-order arg at two types", run = namedLocalAsArgMulti expectFn }
    ]


{-| Builds a program whose `testValue` is
`let identity x = x in ( identity 1, identity "hello" )`, and passes the
program to `expectFn`.
-}
identityMulti : (Src.Module -> Expectation) -> (() -> Expectation)
identityMulti expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "identity" [ pVar "x" ] (varExpr "x") ]
                    (tupleExpr
                        (callExpr (varExpr "identity") [ intExpr 1 ])
                        (callExpr (varExpr "identity") [ strExpr "hello" ])
                    )
                )
    in
    expectFn modul


{-| Builds a program whose `testValue` is
`let const a b = a in ( const 1 "hi", const "hi" 1 )`, and passes the program
to `expectFn`.
-}
constMulti : (Src.Module -> Expectation) -> (() -> Expectation)
constMulti expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "const" [ pVar "a", pVar "b" ] (varExpr "a") ]
                    (tupleExpr
                        (callExpr (varExpr "const") [ intExpr 1, strExpr "hi" ])
                        (callExpr (varExpr "const") [ strExpr "hi", intExpr 1 ])
                    )
                )
    in
    expectFn modul


{-| Builds a program with a local `apply f x = f x`, used as
`apply (\n -> n + 1) 1` and `apply (\s -> s) "hi"`, and passes the program to
`expectFn`.
-}
applyMulti : (Src.Module -> Expectation) -> (() -> Expectation)
applyMulti expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "apply"
                        [ pVar "f", pVar "x" ]
                        (callExpr (varExpr "f") [ varExpr "x" ])
                    ]
                    (tupleExpr
                        (callExpr (varExpr "apply")
                            [ lambdaExpr [ pVar "n" ]
                                (binopsExpr [ ( varExpr "n", "+" ) ] (intExpr 1))
                            , intExpr 1
                            ]
                        )
                        (callExpr (varExpr "apply")
                            [ lambdaExpr [ pVar "s" ] (varExpr "s")
                            , strExpr "hi"
                            ]
                        )
                    )
                )
    in
    expectFn modul


{-| Builds a program with local definitions `compose f g x = f (g x)` and
`addOne n = n + 1`, used as `compose addOne addOne 1` and
`compose addOne addOne 2`, and passes the program to `expectFn`. Both uses
pass `addOne`, `addOne` and a number.
-}
composeMulti : (Src.Module -> Expectation) -> (() -> Expectation)
composeMulti expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "compose"
                        [ pVar "f", pVar "g", pVar "x" ]
                        (callExpr (varExpr "f")
                            [ callExpr (varExpr "g") [ varExpr "x" ] ]
                        )
                    , define "addOne"
                        [ pVar "n" ]
                        (binopsExpr [ ( varExpr "n", "+" ) ] (intExpr 1))
                    ]
                    (tupleExpr
                        (callExpr (varExpr "compose")
                            [ varExpr "addOne", varExpr "addOne", intExpr 1 ]
                        )
                        (callExpr (varExpr "compose")
                            [ varExpr "addOne", varExpr "addOne", intExpr 2 ]
                        )
                    )
                )
    in
    expectFn modul


{-| Builds a program with a local `length` whose non-empty branch is
`1 + length rest`, applied to `[ 1, 2 ]` and `[ "a", "b" ]`, and passes the
program to `expectFn`.
-}
lengthMulti : (Src.Module -> Expectation) -> (() -> Expectation)
lengthMulti expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "length"
                        [ pVar "xs" ]
                        (caseExpr (varExpr "xs")
                            [ ( pList [], intExpr 0 )
                            , ( pCons pAnything (pVar "rest")
                              , binopsExpr
                                    [ ( intExpr 1, "+" ) ]
                                    (callExpr (varExpr "length") [ varExpr "rest" ])
                              )
                            ]
                        )
                    ]
                    (tupleExpr
                        (callExpr (varExpr "length") [ listExpr [ intExpr 1, intExpr 2 ] ])
                        (callExpr (varExpr "length") [ listExpr [ strExpr "a", strExpr "b" ] ])
                    )
                )
    in
    expectFn modul


{-| Builds a program with a local `foldl f acc xs` whose non-empty branch is
the tail call `foldl f (f x acc) rest`, used to fold `[ 1, 2, 3 ]` with
`\x acc -> x + acc` and `[ "a", "b" ]` with `\x acc -> acc + 1`, both from
`0`, and passes the program to `expectFn`.
-}
foldlMulti : (Src.Module -> Expectation) -> (() -> Expectation)
foldlMulti expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "foldl"
                        [ pVar "f", pVar "acc", pVar "xs" ]
                        (caseExpr (varExpr "xs")
                            [ ( pList [], varExpr "acc" )
                            , ( pCons (pVar "x") (pVar "rest")
                              , callExpr (varExpr "foldl")
                                    [ varExpr "f"
                                    , callExpr (varExpr "f") [ varExpr "x", varExpr "acc" ]
                                    , varExpr "rest"
                                    ]
                              )
                            ]
                        )
                    ]
                    (tupleExpr
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
                    )
                )
    in
    expectFn modul


{-| Builds a program with a local `map` whose non-empty branch is
`f x :: map f rest`, mapping `\n -> n + 1` over `[ 1, 2 ]` and `\s -> s` over
`[ "a", "b" ]`, and passes the program to `expectFn`.
-}
mapMulti : (Src.Module -> Expectation) -> (() -> Expectation)
mapMulti expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "map"
                        [ pVar "f", pVar "xs" ]
                        (caseExpr (varExpr "xs")
                            [ ( pList [], listExpr [] )
                            , ( pCons (pVar "x") (pVar "rest")
                              , binopsExpr
                                    [ ( callExpr (varExpr "f") [ varExpr "x" ], "::" ) ]
                                    (callExpr (varExpr "map") [ varExpr "f", varExpr "rest" ])
                              )
                            ]
                        )
                    ]
                    (tupleExpr
                        (callExpr (varExpr "map")
                            [ lambdaExpr [ pVar "n" ]
                                (binopsExpr [ ( varExpr "n", "+" ) ] (intExpr 1))
                            , listExpr [ intExpr 1, intExpr 2 ]
                            ]
                        )
                        (callExpr (varExpr "map")
                            [ lambdaExpr [ pVar "s" ] (varExpr "s")
                            , listExpr [ strExpr "a", strExpr "b" ]
                            ]
                        )
                    )
                )
    in
    expectFn modul


{-| Builds a program with the same local `map` as `mapMulti`, together with
`mapAddOne = map (\n -> n + 1)` and `mapId = map (\s -> s)`, used as
`mapAddOne [ 1, 2 ]` and `mapId [ "a", "b" ]`, and passes the program to
`expectFn`. The `let` body never calls `map` directly.
-}
mapPartialMulti : (Src.Module -> Expectation) -> (() -> Expectation)
mapPartialMulti expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "map"
                        [ pVar "f", pVar "xs" ]
                        (caseExpr (varExpr "xs")
                            [ ( pList [], listExpr [] )
                            , ( pCons (pVar "x") (pVar "rest")
                              , binopsExpr
                                    [ ( callExpr (varExpr "f") [ varExpr "x" ], "::" ) ]
                                    (callExpr (varExpr "map") [ varExpr "f", varExpr "rest" ])
                              )
                            ]
                        )
                    , define "mapAddOne"
                        []
                        (callExpr (varExpr "map")
                            [ lambdaExpr [ pVar "n" ]
                                (binopsExpr [ ( varExpr "n", "+" ) ] (intExpr 1))
                            ]
                        )
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
                )
    in
    expectFn modul


{-| Builds a program whose `testValue` is
`let pair a b = ( a, b ) in ( pair 1 "hi", pair "hi" 1 )`, and passes the
program to `expectFn`.
-}
pairMulti : (Src.Module -> Expectation) -> (() -> Expectation)
pairMulti expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "pair"
                        [ pVar "a", pVar "b" ]
                        (tupleExpr (varExpr "a") (varExpr "b"))
                    ]
                    (tupleExpr
                        (callExpr (varExpr "pair") [ intExpr 1, strExpr "hi" ])
                        (callExpr (varExpr "pair") [ strExpr "hi", intExpr 1 ])
                    )
                )
    in
    expectFn modul


{-| Builds a program with a local `reverseHelper acc xs` whose non-empty branch
is the tail call `reverseHelper (x :: acc) rest`, and a local
`reverse xs = reverseHelper [] xs` applied to `[ 1, 2 ]` and `[ "a", "b" ]`,
and passes the program to `expectFn`. The `let` body calls `reverseHelper` only
through `reverse`.
-}
reverseMulti : (Src.Module -> Expectation) -> (() -> Expectation)
reverseMulti expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "reverseHelper"
                        [ pVar "acc", pVar "xs" ]
                        (caseExpr (varExpr "xs")
                            [ ( pList [], varExpr "acc" )
                            , ( pCons (pVar "x") (pVar "rest")
                              , callExpr (varExpr "reverseHelper")
                                    [ binopsExpr [ ( varExpr "x", "::" ) ] (varExpr "acc")
                                    , varExpr "rest"
                                    ]
                              )
                            ]
                        )
                    , define "reverse"
                        [ pVar "xs" ]
                        (callExpr (varExpr "reverseHelper") [ listExpr [], varExpr "xs" ])
                    ]
                    (tupleExpr
                        (callExpr (varExpr "reverse") [ listExpr [ intExpr 1, intExpr 2 ] ])
                        (callExpr (varExpr "reverse") [ listExpr [ strExpr "a", strExpr "b" ] ])
                    )
                )
    in
    expectFn modul


{-| Builds a program with a local `twice f x = f (f x)`, used as
`twice (\n -> n + 1) 0` and `twice (\s -> s) "hi"`, and passes the program to
`expectFn`.
-}
twiceMulti : (Src.Module -> Expectation) -> (() -> Expectation)
twiceMulti expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "twice"
                        [ pVar "f", pVar "x" ]
                        (callExpr (varExpr "f")
                            [ callExpr (varExpr "f") [ varExpr "x" ] ]
                        )
                    ]
                    (tupleExpr
                        (callExpr (varExpr "twice")
                            [ lambdaExpr [ pVar "n" ]
                                (binopsExpr [ ( varExpr "n", "+" ) ] (intExpr 1))
                            , intExpr 0
                            ]
                        )
                        (callExpr (varExpr "twice")
                            [ lambdaExpr [ pVar "s" ] (varExpr "s")
                            , strExpr "hi"
                            ]
                        )
                    )
                )
    in
    expectFn modul


{-| Builds a program whose `testValue` is
`let singleton x = [ x ] in ( singleton 42, singleton "hi" )`, and passes the
program to `expectFn`.
-}
singletonMulti : (Src.Module -> Expectation) -> (() -> Expectation)
singletonMulti expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "singleton"
                        [ pVar "x" ]
                        (listExpr [ varExpr "x" ])
                    ]
                    (tupleExpr
                        (callExpr (varExpr "singleton") [ intExpr 42 ])
                        (callExpr (varExpr "singleton") [ strExpr "hi" ])
                    )
                )
    in
    expectFn modul


{-| Builds a program with local definitions `identity x = x` and
`apply f x = f x`, with the body `apply identity 42`, and passes the program to
`expectFn`. Each local is used at one type only.
-}
namedLocalAsArg : (Src.Module -> Expectation) -> (() -> Expectation)
namedLocalAsArg expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "identity" [ pVar "x" ] (varExpr "x")
                    , define "apply"
                        [ pVar "f", pVar "x" ]
                        (callExpr (varExpr "f") [ varExpr "x" ])
                    ]
                    (callExpr (varExpr "apply")
                        [ varExpr "identity", intExpr 42 ]
                    )
                )
    in
    expectFn modul


{-| Builds a program with the same local `identity` and `apply` as
`namedLocalAsArg`, with the body `( apply identity 42, apply identity "hello" )`,
and passes the program to `expectFn`.
-}
namedLocalAsArgMulti : (Src.Module -> Expectation) -> (() -> Expectation)
namedLocalAsArgMulti expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "identity" [ pVar "x" ] (varExpr "x")
                    , define "apply"
                        [ pVar "f", pVar "x" ]
                        (callExpr (varExpr "f") [ varExpr "x" ])
                    ]
                    (tupleExpr
                        (callExpr (varExpr "apply")
                            [ varExpr "identity", intExpr 42 ]
                        )
                        (callExpr (varExpr "apply")
                            [ varExpr "identity", strExpr "hello" ]
                        )
                    )
                )
    in
    expectFn modul
