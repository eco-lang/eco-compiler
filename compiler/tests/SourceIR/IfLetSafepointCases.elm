module SourceIR.IfLetSafepointCases exposing (expectSuite)

{-| Source programs in which a variable bound inside one branch of an `if` must
not be treated as in scope after the `if`, for a caller to compile and check.

In the MLIR the code generator emits, the branches of an `if` are separate
regions, and an SSA value defined inside a region cannot be named outside it.
The code generator keeps a mapping from Elm variable names to SSA values. If a
name bound in a branch stayed in that mapping after the `if`, a later operation
could be given an operand that is out of scope, and the MLIR would be invalid.
One place such a name could surface is the list of GC-root hints the code
generator can attach to a call or an allocation: the values of type
`!eco.value` (a boxed heap value, such as a `String`, a `List` or a custom
type) that it treats as live there. What goes into that hint list is decided
in `Compiler.Generate.MLIR.Context`, whose `liveEcoValueVars` at present
returns no values.

Each case is a module named `Test` with two annotated top-level values. The
first is a function whose body is a `let` binding a name (two names in the last
case) to an `if`. The `then` branch binds nothing; the `else` branch is a
`case` whose pattern binds a variable to a `String` taken from its subject. The
second, `testValue`, applies that function to literal arguments.

This module asserts nothing itself. `expectSuite` applies the expectation
function its caller passes to each case in order, stopping at the first that
fails, so what is checked depends on that function. The cases are:

  - `ifElseListDestructure`: the `else` branch takes the head of a
    `List String`.
  - `ifElseCustomDestructure`: the `else` branch takes the first `String` field
    of a single-constructor custom type.
  - `twoSequentialIfLet`: two `let` bindings in a row, each an `if` whose
    `else` branch takes the `String` field of a single-constructor custom type,
    followed by one list built from both.

Among what is not tested: a variable bound in a `then` branch, an `if` with
`else if` branches, a variable bound by a `let` inside a branch rather than by
a `case` pattern, and a bound value that is not a `String`.

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
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Returns one test, named "If-let-safepoint cases " followed by `condStr`,
that applies `expectFn` to each case in turn until one fails. A failure is
reported as `Compiler.BulkCheck.bulkCheck` describes.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("If-let-safepoint cases " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns the three cases, each labelled and applying `expectFn` to its
module.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "If-else with list destructure leaks !eco.value binding", run = ifElseListDestructure expectFn }
    , { label = "If-else with custom type destructure leaks !eco.value binding", run = ifElseCustomDestructure expectFn }
    , { label = "Two sequential if-let with !eco.value leaks", run = twoSequentialIfLet expectFn }
    ]


{-| Applies `expectFn` to a module equivalent to the following, in which the
`else` branch binds `x` to the head of `items`.

    f : Bool -> List String -> String -> List String
    f flag items fallback =
        let
            val =
                if flag then
                    fallback

                else
                    case items of
                        x :: _ ->
                            x

                        [] ->
                            fallback
        in
        val :: []

    testValue : List String
    testValue =
        f False ("hello" :: []) "default"

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


{-| Applies `expectFn` to a module equivalent to the following, in which the
`else` branch binds `name` to a field of a custom type.

    type Pair
        = MkPair String String

    g : Bool -> Pair -> String -> List String
    g flag pair fallback =
        let
            val =
                if flag then
                    fallback

                else
                    case pair of
                        MkPair name _ ->
                            name
        in
        val :: []

    testValue : List String
    testValue =
        g True (MkPair "hello" "world") "default"

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


{-| Applies `expectFn` to a module equivalent to the following, in which each
of two `let` bindings in a row is an `if` whose `else` branch binds a variable,
`s1` and then `s2`.

    type Box
        = Box String

    h : Bool -> Box -> Box -> List String
    h flag b1 b2 =
        let
            x =
                if flag then
                    "a"

                else
                    case b1 of
                        Box s1 ->
                            s1

            y =
                if flag then
                    "b"

                else
                    case b2 of
                        Box s2 ->
                            s2
        in
        x :: y :: []

    testValue : List String
    testValue =
        h True (Box "hello") (Box "world")

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
