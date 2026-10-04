module SourceIR.TypeCheckFailsCases exposing (expectSuite)

{-| Programs that must fail type checking, so that checks on the compiler can
be run on ill-typed input as well as on programs that compile.

With them, a check run through `expectSuite` also sees input with a type error,
so a stage that misbehaves on one, or two type-checking paths that disagree
about whether a program is rejected, can show up as a failure.

The module asserts nothing itself. `expectSuite` takes the expectation to apply
to each program, so what is checked, and after which stage, is decided by the
caller.

Each case builds a `Src.Module` with `Compiler.AST.SourceBuilder`, either with
`makeModule` (a module named `Test` whose one value, `testValue`, holds the
program) or with `makeModuleWithDefs`. Both import only `Basics` and `List`.
Every name a program uses is bound in the program itself, apart from `True`
and `+`, which come from `Basics`. The cases, by label, and the type error each
contains:

  - "Alias everywhere": `allAliased` takes a pair pattern aliased as `whole`,
    whose two parts are aliased as `first` and `second`, and puts all three in
    one list, so a pair and its own components must share a type.
  - "Multiple aliases in recursive function": a local `go` with aliased
    parameters calls itself with `0` as the first argument and its first
    parameter as the second, which makes both parameters numbers, and is then
    called with `[]` as the second.
  - "Case on unit": a `case` on the pair `(1, 1)` with the single pattern `()`.
  - "Case on int": a `case` on `42` whose branches return the string `"zero"`
    and the scrutinee itself.
  - "All expression types in one module": a list of literals mixing a number,
    a string and a char, inside an outer list that mixes that list with
    tuples and numbers.
  - "Fold-like function": a local `myFold` whose step function must return the
    type of the accumulator, applied to a step that returns the pair of its
    arguments, so the accumulator would have to contain itself.
  - "Multiple aliases in destruct": a `let` that destructures the pair `(1, 2)`
    through the same aliased pattern as "Alias everywhere" and lists the pair
    with its parts.
  - "Deeply recursive function": a local `countdown` that returns a list
    holding its argument next to the list returned by a recursive call.
  - "Mutually recursive different types": a local `toInt`, which cases on a
    list, applied to `0` by a local `toList`. Despite the label, `toInt` does
    not call `toList`.
  - "Recursive with record pattern": a local `getValue` that destructures a
    record with fields `value` and `next` and calls itself on `next`, so the
    record's type would have to contain itself. It is applied to a chain of
    three such records, the last of which has the empty record as its `next`.
  - "Recursive higher order": a local `map` that returns `f h` and the
    recursive result `map f t` side by side in one list, so a list element
    would have to be a list of its own type.
  - "Update with computed value": a record update that sets the number field
    `value` of `{ value = 10 }` to the pair `(1, 2)`. An update gives its result
    the type of the record it updates, so a field cannot change type.

Among what is not tested: any program with a type annotation, a custom type or
an import beyond `Basics` and `List`. Nothing here, and nothing `expectSuite`
requires of `expectFn`, checks that a program is in fact rejected, or with
which type error.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( accessExpr
        , accessorExpr
        , binopsExpr
        , boolExpr
        , callExpr
        , caseExpr
        , chrExpr
        , define
        , destruct
        , floatExpr
        , ifExpr
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModule
        , makeModuleWithDefs
        , negateExpr
        , pAlias
        , pAnything
        , pCons
        , pInt
        , pList
        , pRecord
        , pTuple
        , pUnit
        , pVar
        , recordExpr
        , strExpr
        , tuple3Expr
        , tupleExpr
        , updateExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Creates one test, named "Type check failure tests " followed by `condStr`,
that runs the cases in this module in order, each applying `expectFn` to its
program, and stops at the first that fails.

The cases run under `Compiler.BulkCheck.bulkCheck`, so the test passes only if
every case passes, and a failure names only the first failing case.

-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Type check failure tests " ++ condStr) (\() -> bulkCheck (testCases expectFn))


{-| Returns every case in this module, each applying `expectFn` to its program,
grouped by the feature the program is built around.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    asPatternCases expectFn
        ++ caseCases expectFn
        ++ edgeCaseCases expectFn
        ++ higherOrderCases expectFn
        ++ letDestructCases expectFn
        ++ letRecCases expectFn
        ++ recordCases expectFn



-- ============================================================================
-- AS PATTERNS
-- ============================================================================


{-| Returns the cases built around `as` patterns, each applying `expectFn` to its
program.
-}
asPatternCases : (Src.Module -> Expectation) -> List TestCase
asPatternCases expectFn =
    [ { label = "Alias everywhere", run = aliasEverywhere expectFn }
    , { label = "Multiple aliases in recursive function", run = multipleAliasesInRecursiveFunction expectFn }
    ]


{-| Applies `expectFn` to a program that lists a pair alongside its own
components, which cannot share a type.
-}
aliasEverywhere : (Src.Module -> Expectation) -> (() -> Expectation)
aliasEverywhere expectFn _ =
    let
        pattern =
            pAlias
                (pTuple
                    (pAlias (pVar "a") "first")
                    (pAlias (pVar "b") "second")
                )
                "whole"

        modul =
            makeModuleWithDefs "Test"
                [ ( "allAliased", [ pattern ], listExpr [ varExpr "whole", varExpr "first", varExpr "second" ] )
                , ( "testValue", [], callExpr (varExpr "allAliased") [ tupleExpr (intExpr 1) (intExpr 2) ] )
                ]
    in
    expectFn modul


{-| Applies `expectFn` to a program whose recursive `go` forces both parameters
to be numbers and is then called with `[]` as the second argument.
-}
multipleAliasesInRecursiveFunction : (Src.Module -> Expectation) -> (() -> Expectation)
multipleAliasesInRecursiveFunction expectFn _ =
    let
        fn =
            define "go"
                [ pAlias (pVar "n") "count", pAlias (pVar "acc") "result" ]
                (ifExpr (boolExpr True)
                    (varExpr "result")
                    (callExpr (varExpr "go") [ intExpr 0, varExpr "count" ])
                )

        modul =
            makeModule "testValue" (letExpr [ fn ] (callExpr (varExpr "go") [ intExpr 5, listExpr [] ]))
    in
    expectFn modul



-- ============================================================================
-- CASE EXPRESSIONS
-- ============================================================================


{-| Returns the cases built around `case` expressions, each applying `expectFn`
to its program.
-}
caseCases : (Src.Module -> Expectation) -> List TestCase
caseCases expectFn =
    [ { label = "Case on unit", run = caseOnUnit expectFn }
    , { label = "Case on int", run = caseOnInt expectFn }
    ]


{-| Applies `expectFn` to a program that matches the pair `(1, 1)` against the
unit pattern.
-}
caseOnUnit : (Src.Module -> Expectation) -> (() -> Expectation)
caseOnUnit expectFn _ =
    let
        modul =
            makeModule "testValue"
                (caseExpr (tupleExpr (intExpr 1) (intExpr 1))
                    [ ( pUnit, intExpr 0 )
                    ]
                )
    in
    expectFn modul


{-| Applies `expectFn` to a program whose `case` on `42` returns a string from
one branch and a number from the other.
-}
caseOnInt : (Src.Module -> Expectation) -> (() -> Expectation)
caseOnInt expectFn _ =
    let
        modul =
            makeModule "testValue"
                (caseExpr (intExpr 42)
                    [ ( pInt 0, strExpr "zero" )
                    , ( pVar "x", varExpr "x" )
                    ]
                )
    in
    expectFn modul



-- ============================================================================
-- MANY EXPRESSION KINDS
-- ============================================================================


{-| Returns the case that combines many kinds of expression in one program,
applying `expectFn` to it.
-}
edgeCaseCases : (Src.Module -> Expectation) -> List TestCase
edgeCaseCases expectFn =
    [ { label = "All expression types in one module", run = allExpressionTypesInOneModule expectFn }
    ]


{-| Applies `expectFn` to a program that puts literals, tuples, a record, a local
function, `if`, `case`, a negated operand, a field access and an accessor into
lists whose elements do not share a type.
-}
allExpressionTypesInOneModule : (Src.Module -> Expectation) -> (() -> Expectation)
allExpressionTypesInOneModule expectFn _ =
    let
        literals =
            listExpr [ intExpr 1, floatExpr 2.0, strExpr "s", chrExpr "c" ]

        containers =
            tupleExpr
                (recordExpr [ ( "x", intExpr 1 ) ])
                (tuple3Expr (intExpr 1) (intExpr 2) (intExpr 3))

        functions =
            letExpr
                [ define "f" [ pVar "x" ] (varExpr "x") ]
                (callExpr (varExpr "f") [ intExpr 0 ])

        control =
            ifExpr (boolExpr True)
                (caseExpr (intExpr 1) [ ( pVar "n", varExpr "n" ) ])
                (intExpr 0)

        operators =
            binopsExpr
                [ ( negateExpr (intExpr 1), "+" ) ]
                (intExpr 2)

        records =
            letExpr
                [ define "r" [] (recordExpr [ ( "x", intExpr 1 ) ]) ]
                (tupleExpr
                    (accessExpr (varExpr "r") "x")
                    (accessorExpr "x")
                )

        modul =
            makeModule "testValue"
                (listExpr [ literals, containers, functions, control, operators, records ])
    in
    expectFn modul



-- ============================================================================
-- HIGHER-ORDER FUNCTIONS
-- ============================================================================


{-| Returns the case built around a function that takes a function, applying
`expectFn` to it.
-}
higherOrderCases : (Src.Module -> Expectation) -> List TestCase
higherOrderCases expectFn =
    [ { label = "Fold-like function", run = foldLikeFunction expectFn }
    ]


{-| Applies `expectFn` to a program that passes a fold-shaped `myFold` a step
function returning the pair of its arguments, where the step must return the
type of the accumulator.

`myFold` applies the step to the head of a non-empty list and does not recurse.

-}
foldLikeFunction : (Src.Module -> Expectation) -> (() -> Expectation)
foldLikeFunction expectFn _ =
    let
        foldFn =
            define "myFold"
                [ pVar "f", pVar "init", pVar "list" ]
                (caseExpr (varExpr "list")
                    [ ( pList [], varExpr "init" )
                    , ( pCons (pVar "h") (pVar "t")
                      , callExpr (varExpr "f") [ varExpr "h", varExpr "init" ]
                      )
                    ]
                )

        addFn =
            lambdaExpr [ pVar "a", pVar "b" ] (tupleExpr (varExpr "a") (varExpr "b"))

        modul =
            makeModule "testValue"
                (letExpr [ foldFn ]
                    (callExpr (varExpr "myFold") [ addFn, intExpr 0, listExpr [ intExpr 1 ] ])
                )
    in
    expectFn modul



-- ============================================================================
-- LET DESTRUCTURING
-- ============================================================================


{-| Returns the case built around a destructuring `let`, applying `expectFn` to
it.
-}
letDestructCases : (Src.Module -> Expectation) -> List TestCase
letDestructCases expectFn =
    [ { label = "Multiple aliases in destruct", run = multipleAliasesInDestruct expectFn }
    ]


{-| Applies `expectFn` to a program that destructures a pair through aliased
patterns and lists the pair alongside its components.
-}
multipleAliasesInDestruct : (Src.Module -> Expectation) -> (() -> Expectation)
multipleAliasesInDestruct expectFn _ =
    let
        pair =
            tupleExpr (intExpr 1) (intExpr 2)

        def =
            destruct
                (pAlias
                    (pTuple
                        (pAlias (pVar "a") "first")
                        (pAlias (pVar "b") "second")
                    )
                    "whole"
                )
                pair

        modul =
            makeModule "testValue"
                (letExpr [ def ]
                    (listExpr [ varExpr "whole", varExpr "first", varExpr "second", varExpr "a", varExpr "b" ])
                )
    in
    expectFn modul



-- ============================================================================
-- RECURSIVE LOCAL FUNCTIONS
-- ============================================================================


{-| Returns the cases built around recursive local functions, each applying
`expectFn` to its program.
-}
letRecCases : (Src.Module -> Expectation) -> List TestCase
letRecCases expectFn =
    [ { label = "Deeply recursive function", run = deeplyRecursiveFn expectFn }
    , { label = "Mutually recursive different types", run = mutuallyRecursiveDifferentTypes expectFn }
    , { label = "Recursive with record pattern", run = recursiveWithRecordPattern expectFn }
    , { label = "Recursive higher order", run = recursiveHigherOrder expectFn }
    ]


{-| Applies `expectFn` to a program whose recursive `countdown` puts its argument
and its own result in one list.
-}
deeplyRecursiveFn : (Src.Module -> Expectation) -> (() -> Expectation)
deeplyRecursiveFn expectFn _ =
    let
        fn =
            define "countdown"
                [ pVar "n" ]
                (caseExpr (varExpr "n")
                    [ ( pInt 0, listExpr [] )
                    , ( pVar "x", listExpr [ varExpr "x", callExpr (varExpr "countdown") [ intExpr 0 ] ] )
                    ]
                )

        modul =
            makeModule "testValue" (letExpr [ fn ] (callExpr (varExpr "countdown") [ intExpr 3 ]))
    in
    expectFn modul


{-| Applies `expectFn` to a program in which `toList` calls `toInt`, which cases
on a list, with the number `0`.

Only `toList` refers to the other function, so the two are not mutually
recursive.

-}
mutuallyRecursiveDifferentTypes : (Src.Module -> Expectation) -> (() -> Expectation)
mutuallyRecursiveDifferentTypes expectFn _ =
    let
        toList =
            define "toList"
                [ pVar "n" ]
                (ifExpr (boolExpr True)
                    (listExpr [])
                    (listExpr [ callExpr (varExpr "toInt") [ intExpr 0 ] ])
                )

        toInt =
            define "toInt"
                [ pVar "xs" ]
                (caseExpr (varExpr "xs")
                    [ ( pList [], intExpr 0 )
                    , ( pAnything, intExpr 1 )
                    ]
                )

        modul =
            makeModule "testValue" (letExpr [ toList, toInt ] (callExpr (varExpr "toList") [ intExpr 3 ]))
    in
    expectFn modul


{-| Applies `expectFn` to a program whose `getValue` destructures a record and
calls itself on the record's `next` field, so the record's type would have to
contain itself.
-}
recursiveWithRecordPattern : (Src.Module -> Expectation) -> (() -> Expectation)
recursiveWithRecordPattern expectFn _ =
    let
        fn =
            define "getValue"
                [ pRecord [ "value", "next" ] ]
                (ifExpr (boolExpr True)
                    (varExpr "value")
                    (callExpr (varExpr "getValue") [ varExpr "next" ])
                )

        arg =
            recordExpr
                [ ( "value", intExpr 1 )
                , ( "next", recordExpr [ ( "value", intExpr 2 ), ( "next", recordExpr [ ( "value", intExpr 3 ), ( "next", recordExpr [] ) ] ) ] )
                ]

        modul =
            makeModule "testValue" (letExpr [ fn ] (callExpr (varExpr "getValue") [ arg ]))
    in
    expectFn modul


{-| Applies `expectFn` to a program whose `map` returns `f h` and its own
recursive result as elements of one list.
-}
recursiveHigherOrder : (Src.Module -> Expectation) -> (() -> Expectation)
recursiveHigherOrder expectFn _ =
    let
        fn =
            define "map"
                [ pVar "f", pVar "list" ]
                (caseExpr (varExpr "list")
                    [ ( pList [], listExpr [] )
                    , ( pCons (pVar "h") (pVar "t")
                      , listExpr
                            [ callExpr (varExpr "f") [ varExpr "h" ]
                            , callExpr (varExpr "map") [ varExpr "f", varExpr "t" ]
                            ]
                      )
                    ]
                )

        addOne =
            lambdaExpr [ pVar "x" ] (varExpr "x")

        modul =
            makeModule "testValue"
                (letExpr [ fn ]
                    (callExpr (varExpr "map") [ addOne, listExpr [ intExpr 1, intExpr 2 ] ])
                )
    in
    expectFn modul



-- ============================================================================
-- RECORD UPDATE
-- ============================================================================


{-| Returns the case built around record update, applying `expectFn` to it.
-}
recordCases : (Src.Module -> Expectation) -> List TestCase
recordCases expectFn =
    [ { label = "Update with computed value", run = updateWithComputedValue expectFn }
    ]


{-| Applies `expectFn` to a program that updates the number field `value` of a
record to a pair, which a record update does not allow.
-}
updateWithComputedValue : (Src.Module -> Expectation) -> (() -> Expectation)
updateWithComputedValue expectFn _ =
    let
        record =
            recordExpr [ ( "value", intExpr 10 ) ]

        def =
            define "r" [] record

        newValue =
            tupleExpr (intExpr 1) (intExpr 2)

        update =
            updateExpr (varExpr "r") [ ( "value", newValue ) ]

        modul =
            makeModule "testValue" (letExpr [ def ] update)
    in
    expectFn modul
