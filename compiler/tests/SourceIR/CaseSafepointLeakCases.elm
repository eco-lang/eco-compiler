module SourceIR.CaseSafepointLeakCases exposing (expectSuite)

{-| Programs for checking that a value defined inside one alternative of a
`case` is not used after the `case`. In each, a `case` bound by a `let` yields a
boxed value from each alternative and a heap allocation follows the `case`, and
each program is handed to an expectation function the caller supplies.

When a `case` is lowered to an `eco.case` op, its alternatives are placed in
that op's regions (or those of nested `eco.case` ops), and an SSA value defined
inside one region cannot be used outside it. The code generator tracks which
values are in scope through `varMappings` and `definedSsaVars` in
`Compiler.Generate.MLIR.Context`. `ctxForSiblingRegion` sets both back to their
state just before the `eco.case` op at the start of each alternative after the
first. `ctxAfterBranchOp` sets `varMappings` back to that state after the
`case`, and `definedSsaVars` to that state plus the result variables of the
branch construct. If a value defined inside an alternative stayed in scope
afterwards, an op after the `case` could name it, for example as a GC root hint:
a live `!eco.value` operand appended to an allocating op, though
`Context.liveEcoValueVars` currently returns no hints. The "safepoint" in the
module's name is the point at which an allocation may run the garbage collector.

A `case` that reaches MLIR generation as a case, and whose decision tree tests
its scrutinee, is lowered by the decision-tree code of
`Compiler.Generate.MLIR.Expr` as a chain of tests or a fan-out, each with a
Bool form and a general one (`generateChainForBoolADTWithJumps`,
`generateChainGeneralWithJumps`, `generateBoolFanOutWithJumps`,
`generateFanOutGeneralWithJumps`). Which of the four a program reaches depends
on the decision tree built for it, and nothing here checks which one is used.

Each program is a module named `Test` built with
`makeModuleWithTypedDefsUnionsAliases`, which imports `Maybe` among the
standard modules. The function holding the `case` binds its result in a `let`
and returns it consed onto `[]`, and `testValue` applies that function to fixed
arguments. The module builds the programs and asserts nothing itself:
`expectFn` decides what is checked. The four programs are:

  - a `case` on a `Bool` whose alternatives return parameters
    (`boolCaseWithAlloc`);
  - a `case` on a three-constructor enumeration whose alternatives are string
    literals (`multiCtorCaseWithAlloc`);
  - a `case` on a `Maybe (Maybe String)` with a nested `case` in its `Just`
    alternative (`nestedCaseWithAlloc`);
  - a `case` on a two-constructor type whose alternatives call a local
    function (`caseWithCallThenAlloc`).

Among what is not tested: an outermost `case` whose result is not bound by a
`let`, a `case` on an `Int`, `Char` or `String` pattern, an alternative that
builds a list, record or constructor value, and an allocation after the `case`
other than `::`.

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
        , letExpr
        , listExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pCtor
        , pVar
        , strExpr
        , tLambda
        , tType
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Creates one test, titled "Case safepoint leak cases " followed by
`condStr`, that applies `expectFn` to each of the four programs in turn.

The cases run through `Compiler.BulkCheck.bulkCheck`, so the test reports only
the first failing case, labelled, and the cases after it do not run.

-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Case safepoint leak cases " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns the four labelled cases, in the order they run, each applying
`expectFn` to its program.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "Bool case with temporaries then allocation", run = boolCaseWithAlloc expectFn }
    , { label = "Multi-ctor case with temporaries then allocation", run = multiCtorCaseWithAlloc expectFn }
    , { label = "Nested case with temporaries then allocation", run = nestedCaseWithAlloc expectFn }
    , { label = "Case with function call in alternative then allocation", run = caseWithCallThenAlloc expectFn }
    ]


{-| Applies `expectFn` to a program whose `case` is on a `Bool` and returns one
of two `String` parameters, and whose `testValue` is `f True "hello" "world"`.

    f : Bool -> String -> String -> List String
    f flag a b =
        let
            val =
                case flag of
                    True ->
                        a

                    False ->
                        b
        in
        val :: []

-}
boolCaseWithAlloc : (Src.Module -> Expectation) -> (() -> Expectation)
boolCaseWithAlloc expectFn _ =
    let
        fDef : TypedDef
        fDef =
            { name = "f"
            , tipe =
                tLambda (tType "Bool" [])
                    (tLambda (tType "String" [])
                        (tLambda (tType "String" [])
                            (tType "List" [ tType "String" [] ])
                        )
                    )
            , args = [ pVar "flag", pVar "a", pVar "b" ]
            , body =
                letExpr
                    [ define "val"
                        []
                        (caseExpr (varExpr "flag")
                            [ ( pCtor "True" [], varExpr "a" )
                            , ( pCtor "False" [], varExpr "b" )
                            ]
                        )
                    ]
                    (binopsExpr [ ( varExpr "val", "::" ) ] (listExpr []))
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "List" [ tType "String" [] ]
            , body = callExpr (varExpr "f") [ ctorExpr "True", strExpr "hello", strExpr "world" ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "Test"
            [ fDef, testValueDef ]
            []
            []
        )


{-| Applies `expectFn` to a program whose `case` is on a three-constructor
enumeration declared in the program, with a string literal in each
alternative, and whose `testValue` is `colorName Green`.

    type Color
        = Red
        | Green
        | Blue

    colorName : Color -> List String
    colorName c =
        let
            name =
                case c of
                    Red ->
                        "red"

                    Green ->
                        "green"

                    Blue ->
                        "blue"
        in
        name :: []

-}
multiCtorCaseWithAlloc : (Src.Module -> Expectation) -> (() -> Expectation)
multiCtorCaseWithAlloc expectFn _ =
    let
        unions : List UnionDef
        unions =
            [ { name = "Color"
              , args = []
              , ctors =
                    [ { name = "Red", args = [] }
                    , { name = "Green", args = [] }
                    , { name = "Blue", args = [] }
                    ]
              }
            ]

        colorNameDef : TypedDef
        colorNameDef =
            { name = "colorName"
            , tipe =
                tLambda (tType "Color" [])
                    (tType "List" [ tType "String" [] ])
            , args = [ pVar "c" ]
            , body =
                letExpr
                    [ define "name"
                        []
                        (caseExpr (varExpr "c")
                            [ ( pCtor "Red" [], strExpr "red" )
                            , ( pCtor "Green" [], strExpr "green" )
                            , ( pCtor "Blue" [], strExpr "blue" )
                            ]
                        )
                    ]
                    (binopsExpr [ ( varExpr "name", "::" ) ] (listExpr []))
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "List" [ tType "String" [] ]
            , body = callExpr (varExpr "colorName") [ ctorExpr "Green" ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "Test"
            [ colorNameDef, testValueDef ]
            unions
            []
        )


{-| Applies `expectFn` to a program whose `case` is on a `Maybe (Maybe String)`
and holds a second `case`, on the inner `Maybe`, in its `Just` alternative.
`Maybe` is the imported one; the program declares no type. Its `testValue` is
`extract (Just (Just "found")) "missing"`.

    extract : Maybe (Maybe String) -> String -> List String
    extract outer fallback =
        let
            val =
                case outer of
                    Just inner ->
                        case inner of
                            Just s ->
                                s

                            Nothing ->
                                fallback

                    Nothing ->
                        fallback
        in
        val :: []

-}
nestedCaseWithAlloc : (Src.Module -> Expectation) -> (() -> Expectation)
nestedCaseWithAlloc expectFn _ =
    let
        extractDef : TypedDef
        extractDef =
            { name = "extract"
            , tipe =
                tLambda (tType "Maybe" [ tType "Maybe" [ tType "String" [] ] ])
                    (tLambda (tType "String" [])
                        (tType "List" [ tType "String" [] ])
                    )
            , args = [ pVar "outer", pVar "fallback" ]
            , body =
                letExpr
                    [ define "val"
                        []
                        (caseExpr (varExpr "outer")
                            [ ( pCtor "Just" [ pVar "inner" ]
                              , caseExpr (varExpr "inner")
                                    [ ( pCtor "Just" [ pVar "s" ], varExpr "s" )
                                    , ( pCtor "Nothing" [], varExpr "fallback" )
                                    ]
                              )
                            , ( pCtor "Nothing" [], varExpr "fallback" )
                            ]
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
                callExpr (varExpr "extract")
                    [ callExpr (ctorExpr "Just") [ callExpr (ctorExpr "Just") [ strExpr "found" ] ]
                    , strExpr "missing"
                    ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "Test"
            [ extractDef, testValueDef ]
            []
            []
        )


{-| Applies `expectFn` to a program whose `case` is on a two-constructor type
declared in the program, each alternative binding the constructor's `String`
and passing it to a call, and whose `testValue` is `describe (Greet "World")`.

    type Action
        = Greet String
        | Farewell String

    describe : Action -> List String
    describe action =
        let
            msg =
                case action of
                    Greet name ->
                        append "Hello, " name

                    Farewell name ->
                        append "Goodbye, " name
        in
        msg :: []

`append : String -> String -> String` is a top-level function of the program,
not `String.append`. Its body calls `a` with no arguments, which source text
cannot write, so it ignores `b` and does not concatenate.

-}
caseWithCallThenAlloc : (Src.Module -> Expectation) -> (() -> Expectation)
caseWithCallThenAlloc expectFn _ =
    let
        unions : List UnionDef
        unions =
            [ { name = "Action"
              , args = []
              , ctors =
                    [ { name = "Greet", args = [ tType "String" [] ] }
                    , { name = "Farewell", args = [ tType "String" [] ] }
                    ]
              }
            ]

        describeDef : TypedDef
        describeDef =
            { name = "describe"
            , tipe =
                tLambda (tType "Action" [])
                    (tType "List" [ tType "String" [] ])
            , args = [ pVar "action" ]
            , body =
                letExpr
                    [ define "msg"
                        []
                        (caseExpr (varExpr "action")
                            [ ( pCtor "Greet" [ pVar "name" ]
                              , callExpr (varExpr "append") [ strExpr "Hello, ", varExpr "name" ]
                              )
                            , ( pCtor "Farewell" [ pVar "name" ]
                              , callExpr (varExpr "append") [ strExpr "Goodbye, ", varExpr "name" ]
                              )
                            ]
                        )
                    ]
                    (binopsExpr [ ( varExpr "msg", "::" ) ] (listExpr []))
            }

        appendDef : TypedDef
        appendDef =
            { name = "append"
            , tipe = tLambda (tType "String" []) (tLambda (tType "String" []) (tType "String" []))
            , args = [ pVar "a", pVar "b" ]
            , body = callExpr (varExpr "a") []
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "List" [ tType "String" [] ]
            , body =
                callExpr (varExpr "describe")
                    [ callExpr (ctorExpr "Greet") [ strExpr "World" ]
                    ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "Test"
            [ appendDef, describeDef, testValueDef ]
            unions
            []
        )
