module SourceIR.TypeCheckFailsCases exposing (expectRejectedSuite, expectSuite)

{-| Programs that must fail type checking, each with the report it must be
rejected with: the type-checking module of the negative catalogue
(`SourceIR.Suite.RejectedSuites`).

`expectRejectedSuite` gives a check each program with its
`SourceIR.Suite.Rejection.Rejection`, the title of the first report (`TYPE
MISMATCH`, `TOO MANY ARGS` or `INFINITE TYPE`) and, for most cases, a fragment
of the report's text; `TestLogic.Reporting.ExpectedRejectionTest` checks that
type checking, and no earlier stage, rejects each program with that report.
`expectSuite` gives a check only the programs, so that checks which hold for
ill-typed input as well (`TestLogic.Canonicalize.IdAssignmentTest`,
`GlobalNamesTest`), and the parity of the two type-checking paths
(`TestLogic.Type.Constrain.TypedErasedCheckingParityTest`, which needs both to
reject each program alike), run on them too.

Each case builds a `Src.Module`, either with `Compiler.AST.SourceBuilder` or
from source text (`SourceIR.Suite.Rejection.fromSource`: a module `Test` with
Elm's default imports, less those the mock interfaces lack). The groups:

  - "Ill-typed programs": twelve programs built around one feature each, the
    first members of this module. Nine are a `TYPE MISMATCH`:
      - "Multiple aliases in recursive function": a local `go` with aliased
        parameters calls itself with `0` as the first argument and its first
        parameter as the second, which makes both parameters numbers, and is
        then called with `[]` as the second.
      - "Case on unit": a `case` on the pair `(1, 1)` with the single pattern
        `()`.
      - "Case on int": a `case` on `42` whose branches return the string
        `"zero"` and the scrutinee itself.
      - "All expression types in one module": a list of literals mixing a
        number, a string and a char, inside an outer list that mixes that list
        with tuples and numbers.
      - "Fold-like function": a local `myFold` whose step function must return
        the type of the accumulator, applied to a step that returns the pair of
        its arguments. `myFold` does not recurse, so the pair is a mismatch,
        not an infinite type.
      - "Multiple aliases in destruct": a `let` that destructures the pair
        `(1, 2)` through aliased patterns and lists the pair with its parts.
      - "Deeply recursive function": a local `countdown` that returns a list
        holding its argument next to the list returned by a recursive call.
      - "Mutually recursive different types": a local `toInt`, which cases on a
        list, applied to `0` by a local `toList`. Despite the label, `toInt`
        does not call `toList`.
      - "Update with computed value": a record update that sets the number
        field `value` of `{ value = 10 }` to the pair `(1, 2)`. An update gives
        its result the type of the record it updates, so a field cannot change
        type.
        Three are an `INFINITE TYPE`:
      - "Alias everywhere": `allAliased` takes a pair pattern aliased as
        `whole`, whose two parts are aliased as `first` and `second`, and puts
        all three in one list, so a pair would have to contain itself.
      - "Recursive with record pattern": a local `getValue` that destructures a
        record with fields `value` and `next` and calls itself on `next`, so the
        record's type would have to contain itself.
      - "Recursive higher order": a local `map` that returns `f h` and the
        recursive result `map f t` side by side in one list, so a list element
        would have to be a list of its own type.
  - "Unification failures": twelve `TYPE MISMATCH` programs, from the former
    `Compiler.Type.UnificationErrorsTest`: an argument, an `if` condition (also
    the outer one of an `if` chain), `if` and `case` branches, list elements,
    an operand of `+` or `++`, and `<` between tuples holding a function in
    each position.
  - "Occurs check": `f x = f` and `apply x = x x`, each an `INFINITE TYPE`
    naming `f` and `x`, from the former `Compiler.Type.OccursCheckTest`.
  - "Annotations": five definitions whose bodies contradict their annotations,
    each a `TYPE MISMATCH` whose report blames the annotation of that
    definition, from the former `Compiler.Type.AnnotationEnforcementTest`, and
    a control whose error, under an annotation, is the operand of `+` instead.
  - "Report categories", "Report problems", "Report contexts", "Report
    operators", "Report type variables", "Report records", "Report patterns",
    "Report infinite types" and "Report type printing": 306 short programs
    written as source text, from the former `Compiler.Type.ErrorReportCoverageTest`,
    whose fragments are the explanation each report must give: the category of
    the mismatched expression under an annotation, the hints of the type diff
    (casts between `Int`, `Float` and `String`, arities, records, rigid and
    constrained type variables, the `?` and `∞` of unknown and infinite
    parts), the surrounding expression, the operators with their own
    explanations, patterns, and the printing of types under aliased and
    exposed imports. That their errors survive the binary form a build caches
    them in is checked by `Compiler.Type.ErrorReportCoverageTest`.
  - "Unannotated recursive groups": two ill-typed groups of unannotated,
    mutually recursive functions, each a `TYPE MISMATCH`, that type checking
    once accepted, as stock Elm 0.19.1 does (`recursiveGroupCases`).

Among what is not tested: errors in effect managers, which cannot be written
against the mock interfaces, and a type error after the first in a program,
other than through a fragment.

-}

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
        , makeModuleWithTypedDefs
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
        , parensExpr
        , recordExpr
        , strExpr
        , tLambda
        , tTuple
        , tType
        , tuple3Expr
        , tupleExpr
        , updateExpr
        , varExpr
        )
import Compiler.IR.Source as Src
import Expect exposing (Expectation)
import SourceIR.Suite.Rejection
    exposing
        ( RejectedCase
        , Rejection
        , expectRejectedSuiteOf
        , expectSuiteOf
        , fromModule
        , fromSource
        , rejectedWith
        , rejectedWithFragment
        )
import Test exposing (Test)


{-| Creates a group of tests, named "Type check failure tests " followed by
`condStr`, with one test per group of cases (see `groups`). Each test applies
`expectFn` to the program of every case of its group in order, under
`Compiler.BulkCheck.bulkCheck`, so it passes only if every case passes, and a
failure names only the first failing case.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("Type check failure tests " ++ condStr)
        (List.map (\( name, cases ) -> expectSuiteOf (name ++ " " ++ condStr) cases expectFn) groups)


{-| `expectSuite`, giving `expectFn` the `Rejection` each case records as well.
-}
expectRejectedSuite : (Src.Module -> Rejection -> Expectation) -> String -> Test
expectRejectedSuite expectFn condStr =
    Test.describe ("Type check failure tests " ++ condStr)
        (List.map (\( name, cases ) -> expectRejectedSuiteOf (name ++ " " ++ condStr) cases expectFn) groups)


{-| Every case in this module, by group, each group under the name its test
gets.
-}
groups : List ( String, List RejectedCase )
groups =
    [ ( "Ill-typed programs"
      , asPatternCases
            ++ caseCases
            ++ edgeCaseCases
            ++ higherOrderCases
            ++ letDestructCases
            ++ letRecCases
            ++ recordCases
      )
    , ( "Unification failures", unificationCases )
    , ( "Occurs check", occursCases )
    , ( "Annotations", annotationCases )
    , ( "Report categories", categoryCases )
    , ( "Report problems", problemCases )
    , ( "Report contexts", contextCases )
    , ( "Report operators", operatorCases )
    , ( "Report type variables", rigidCases )
    , ( "Report records", recordFieldCases )
    , ( "Report patterns", patternMismatchCases )
    , ( "Report infinite types", infiniteCases )
    , ( "Report type printing", printingCases )
    , ( "Unannotated recursive groups", recursiveGroupCases )
    ]



-- ============================================================================
-- AS PATTERNS
-- ============================================================================


{-| Returns the cases built around `as` patterns.
-}
asPatternCases : List RejectedCase
asPatternCases =
    [ fromModule "Alias everywhere" (rejectedWith "INFINITE TYPE") aliasEverywhere
    , fromModule "Multiple aliases in recursive function" (rejectedWith "TYPE MISMATCH") multipleAliasesInRecursiveFunction
    ]


{-| A program that lists a pair alongside its own
components, which cannot share a type.
-}
aliasEverywhere : () -> Src.Module
aliasEverywhere () =
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
    modul


{-| A program whose recursive `go` forces both parameters
to be numbers and is then called with `[]` as the second argument.
-}
multipleAliasesInRecursiveFunction : () -> Src.Module
multipleAliasesInRecursiveFunction () =
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
    modul



-- ============================================================================
-- CASE EXPRESSIONS
-- ============================================================================


{-| Returns the cases built around `case` expressions.
-}
caseCases : List RejectedCase
caseCases =
    [ fromModule "Case on unit" (rejectedWith "TYPE MISMATCH") caseOnUnit
    , fromModule "Case on int" (rejectedWith "TYPE MISMATCH") caseOnInt
    ]


{-| A program that matches the pair `(1, 1)` against the
unit pattern.
-}
caseOnUnit : () -> Src.Module
caseOnUnit () =
    let
        modul =
            makeModule "testValue"
                (caseExpr (tupleExpr (intExpr 1) (intExpr 1))
                    [ ( pUnit, intExpr 0 )
                    ]
                )
    in
    modul


{-| A program whose `case` on `42` returns a string from
one branch and a number from the other.
-}
caseOnInt : () -> Src.Module
caseOnInt () =
    let
        modul =
            makeModule "testValue"
                (caseExpr (intExpr 42)
                    [ ( pInt 0, strExpr "zero" )
                    , ( pVar "x", varExpr "x" )
                    ]
                )
    in
    modul



-- ============================================================================
-- MANY EXPRESSION KINDS
-- ============================================================================


{-| Returns the case that combines many kinds of expression in one program.
-}
edgeCaseCases : List RejectedCase
edgeCaseCases =
    [ fromModule "All expression types in one module" (rejectedWith "TYPE MISMATCH") allExpressionTypesInOneModule
    ]


{-| A program that puts literals, tuples, a record, a local
function, `if`, `case`, a negated operand, a field access and an accessor into
lists whose elements do not share a type.
-}
allExpressionTypesInOneModule : () -> Src.Module
allExpressionTypesInOneModule () =
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
    modul



-- ============================================================================
-- HIGHER-ORDER FUNCTIONS
-- ============================================================================


{-| Returns the case built around a function that takes a function.
-}
higherOrderCases : List RejectedCase
higherOrderCases =
    [ fromModule "Fold-like function" (rejectedWith "TYPE MISMATCH") foldLikeFunction
    ]


{-| A program that passes a fold-shaped `myFold` a step
function returning the pair of its arguments, where the step must return the
type of the accumulator.

`myFold` applies the step to the head of a non-empty list and does not recurse.

-}
foldLikeFunction : () -> Src.Module
foldLikeFunction () =
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
    modul



-- ============================================================================
-- LET DESTRUCTURING
-- ============================================================================


{-| Returns the case built around a destructuring `let`.
-}
letDestructCases : List RejectedCase
letDestructCases =
    [ fromModule "Multiple aliases in destruct" (rejectedWith "TYPE MISMATCH") multipleAliasesInDestruct
    ]


{-| A program that destructures a pair through aliased
patterns and lists the pair alongside its components.
-}
multipleAliasesInDestruct : () -> Src.Module
multipleAliasesInDestruct () =
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
    modul



-- ============================================================================
-- RECURSIVE LOCAL FUNCTIONS
-- ============================================================================


{-| Returns the cases built around recursive local functions.
-}
letRecCases : List RejectedCase
letRecCases =
    [ fromModule "Deeply recursive function" (rejectedWith "TYPE MISMATCH") deeplyRecursiveFn
    , fromModule "Mutually recursive different types" (rejectedWith "TYPE MISMATCH") mutuallyRecursiveDifferentTypes
    , fromModule "Recursive with record pattern" (rejectedWith "INFINITE TYPE") recursiveWithRecordPattern
    , fromModule "Recursive higher order" (rejectedWith "INFINITE TYPE") recursiveHigherOrder
    ]


{-| A program whose recursive `countdown` puts its argument
and its own result in one list.
-}
deeplyRecursiveFn : () -> Src.Module
deeplyRecursiveFn () =
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
    modul


{-| A program in which `toList` calls `toInt`, which cases
on a list, with the number `0`.

Only `toList` refers to the other function, so the two are not mutually
recursive.

-}
mutuallyRecursiveDifferentTypes : () -> Src.Module
mutuallyRecursiveDifferentTypes () =
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
    modul


{-| A program whose `getValue` destructures a record and
calls itself on the record's `next` field, so the record's type would have to
contain itself.
-}
recursiveWithRecordPattern : () -> Src.Module
recursiveWithRecordPattern () =
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
    modul


{-| A program whose `map` returns `f h` and its own
recursive result as elements of one list.
-}
recursiveHigherOrder : () -> Src.Module
recursiveHigherOrder () =
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
    modul



-- ============================================================================
-- RECORD UPDATE
-- ============================================================================


{-| Returns the case built around record update.
-}
recordCases : List RejectedCase
recordCases =
    [ fromModule "Update with computed value" (rejectedWith "TYPE MISMATCH") updateWithComputedValue
    ]


{-| A program that updates the number field `value` of a
record to a pair, which a record update does not allow.
-}
updateWithComputedValue : () -> Src.Module
updateWithComputedValue () =
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
    modul



-- ============================================================================
-- UNIFICATION FAILURES
-- ============================================================================


{-| Programs in which a failed unification must become a type mismatch: the
mismatch group of the former `Compiler.Type.UnificationErrorsTest`. A comment
on each sketches it as Elm source.
-}
unificationCases : List RejectedCase
unificationCases =
    [ -- f : String -> String
      -- f s = s
      -- x : String
      -- x = f 42
      fromModule "Int vs String in function argument"
        (rejectedWith "TYPE MISMATCH")
        (\() ->
            makeModuleWithTypedDefs "TypeMismatch"
                [ { name = "f"
                  , args = [ pVar "s" ]
                  , tipe = tLambda (tType "String" []) (tType "String" [])
                  , body = varExpr "s"
                  }
                , { name = "x"
                  , args = []
                  , tipe = tType "String" []
                  , body = callExpr (varExpr "f") [ intExpr 42 ]
                  }
                ]
        )

    -- x = if 42 then 1 else 2
    , fromModule "Int in if condition"
        (rejectedWith "TYPE MISMATCH")
        (\() ->
            makeModuleWithDefs "IfMismatch"
                [ ( "x", [], ifExpr (intExpr 42) (intExpr 1) (intExpr 2) ) ]
        )

    -- x = if 42 then 1 else if True then 2 else 3
    , fromModule "Int in the outer condition of an if chain"
        (rejectedWith "TYPE MISMATCH")
        (\() ->
            makeModuleWithDefs "IfChainCondMismatch"
                [ ( "x", [], ifExpr (intExpr 42) (intExpr 1) (ifExpr (boolExpr True) (intExpr 2) (intExpr 3)) ) ]
        )

    -- x = (if True then 1 else if False then 2 else 3) ++ "a"
    , fromModule "if chain of numbers used as a String"
        (rejectedWith "TYPE MISMATCH")
        (\() ->
            makeModuleWithDefs "IfChainResultMismatch"
                [ ( "x"
                  , []
                  , binopsExpr
                        [ ( parensExpr
                                (ifExpr
                                    (boolExpr True)
                                    (intExpr 1)
                                    (ifExpr (boolExpr False) (intExpr 2) (intExpr 3))
                                )
                          , "++"
                          )
                        ]
                        (strExpr "a")
                  )
                ]
        )

    -- x = if True then 1 else "hello"
    , fromModule "mismatched if branches"
        (rejectedWith "TYPE MISMATCH")
        (\() ->
            makeModuleWithDefs "BranchMismatch"
                [ ( "x", [], ifExpr (boolExpr True) (intExpr 1) (strExpr "hello") ) ]
        )

    -- x = [1, "hello"]
    , fromModule "mismatched list elements"
        (rejectedWith "TYPE MISMATCH")
        (\() ->
            makeModuleWithDefs "ListMismatch"
                [ ( "x", [], listExpr [ intExpr 1, strExpr "hello" ] ) ]
        )

    -- x n = case n of
    --   0 -> 1
    --   _ -> "hello"
    , fromModule "mismatched case branches"
        (rejectedWith "TYPE MISMATCH")
        (\() ->
            makeModuleWithDefs "CaseMismatch"
                [ ( "x"
                  , [ pVar "n" ]
                  , caseExpr (varExpr "n")
                        [ ( pInt 0, intExpr 1 )
                        , ( pAnything, strExpr "hello" )
                        ]
                  )
                ]
        )

    -- x = 1 + "hello"
    , fromModule "operator type mismatch"
        (rejectedWith "TYPE MISMATCH")
        (\() ->
            makeModuleWithDefs "OpMismatch"
                [ ( "x", [], binopsExpr [ ( intExpr 1, "+" ) ] (strExpr "hello") ) ]
        )

    -- x = (\z -> z, 1) < (\w -> w, 2)
    , fromModule "comparable 2-tuple with non-comparable first element"
        (rejectedWith "TYPE MISMATCH")
        (\() ->
            makeModuleWithDefs "TupleCompFirst"
                [ ( "x"
                  , []
                  , binopsExpr
                        [ ( tupleExpr (lambdaExpr [ pVar "z" ] (varExpr "z")) (intExpr 1), "<" ) ]
                        (tupleExpr (lambdaExpr [ pVar "w" ] (varExpr "w")) (intExpr 2))
                  )
                ]
        )

    -- x = (1, \z -> z, 2) < (3, \w -> w, 4)
    , fromModule "comparable 3-tuple with non-comparable middle element"
        (rejectedWith "TYPE MISMATCH")
        (\() ->
            makeModuleWithDefs "TupleCompMiddle"
                [ ( "x"
                  , []
                  , binopsExpr
                        [ ( tuple3Expr (intExpr 1) (lambdaExpr [ pVar "z" ] (varExpr "z")) (intExpr 2), "<" ) ]
                        (tuple3Expr (intExpr 3) (lambdaExpr [ pVar "w" ] (varExpr "w")) (intExpr 4))
                  )
                ]
        )

    -- x = (\z -> z, 1, 2) < (\w -> w, 3, 4)
    , fromModule "comparable 3-tuple with non-comparable first element"
        (rejectedWith "TYPE MISMATCH")
        (\() ->
            makeModuleWithDefs "TupleComp3First"
                [ ( "x"
                  , []
                  , binopsExpr
                        [ ( tuple3Expr (lambdaExpr [ pVar "z" ] (varExpr "z")) (intExpr 1) (intExpr 2), "<" ) ]
                        (tuple3Expr (lambdaExpr [ pVar "w" ] (varExpr "w")) (intExpr 3) (intExpr 4))
                  )
                ]
        )

    -- x = (1, \z -> z) < (2, \w -> w)
    , fromModule "comparable tuple with non-comparable last element"
        (rejectedWith "TYPE MISMATCH")
        (\() ->
            makeModuleWithDefs "TupleCompLast"
                [ ( "x"
                  , []
                  , binopsExpr
                        [ ( tupleExpr (intExpr 1) (lambdaExpr [ pVar "z" ] (varExpr "z")), "<" ) ]
                        (tupleExpr (intExpr 2) (lambdaExpr [ pVar "w" ] (varExpr "w")))
                  )
                ]
        )
    ]



-- ============================================================================
-- OCCURS CHECK
-- ============================================================================


{-| Definitions whose type would have to contain itself, from the former
`Compiler.Type.OccursCheckTest`. The fragment names the variable the
infinite type is reported for.
-}
occursCases : List RejectedCase
occursCases =
    [ -- f's result type is f's own type: f : a -> (a -> (a -> ...)).
      fromModule "self-referential through function application"
        (rejectedWithFragment "INFINITE TYPE" "self-referential type for f:")
        (\() -> makeModuleWithDefs "SelfRef" [ ( "f", [ pVar "x" ], varExpr "f" ) ])

    -- x is applied to itself: x : a and a = a -> b.
    , fromModule "self-application"
        (rejectedWithFragment "INFINITE TYPE" "self-referential type for x:")
        (\() -> makeModuleWithDefs "SelfApply" [ ( "apply", [ pVar "x" ], callExpr (varExpr "x") [ varExpr "x" ] ) ])
    ]



-- ============================================================================
-- ANNOTATIONS
-- ============================================================================


{-| One annotated definition whose body contradicts its annotation, from the
former `Compiler.Type.AnnotationEnforcementTest`. The fragment names the
annotated definition, so a case shows that the module is rejected because of
the annotation and not for some other type error.

The last case is the control: `f : Int -> Int` with body `x + "a"` is
rejected for the operand of `+`, and its report does not speak of `f`'s
annotation.

-}
annotationCases : List RejectedCase
annotationCases =
    [ fromModule "Int annotation on String value"
        (rejectedWithFragment "TYPE MISMATCH" "the type annotation on `x`")
        (\() -> annotated "MismatchIntStr" "x" [] (tType "Int" []) (strExpr "hello"))
    , fromModule "String annotation on Int value"
        (rejectedWithFragment "TYPE MISMATCH" "the type annotation on `x`")
        (\() -> annotated "MismatchStrInt" "x" [] (tType "String" []) (intExpr 42))
    , fromModule "wrong function return type"
        (rejectedWithFragment "TYPE MISMATCH" "the type annotation on `f`")
        (\() -> annotated "MismatchFuncReturn" "f" [ pVar "x" ] (tLambda (tType "Int" []) (tType "String" [])) (varExpr "x"))
    , fromModule "wrong list element type"
        (rejectedWithFragment "TYPE MISMATCH" "the type annotation on `xs`")
        (\() -> annotated "MismatchListElem" "xs" [] (tType "List" [ tType "String" [] ]) (listExpr [ intExpr 1 ]))
    , fromModule "wrong tuple element type"
        (rejectedWithFragment "TYPE MISMATCH" "the type annotation on `pair`")
        (\() -> annotated "MismatchTupleElem" "pair" [] (tTuple (tType "String" []) (tType "Int" [])) (tupleExpr (intExpr 1) (strExpr "a")))
    , fromModule "an unrelated type error under an annotation"
        (rejectedWithFragment "TYPE MISMATCH" "I cannot do addition with String values")
        (\() -> annotated "UnrelatedError" "f" [ pVar "x" ] (tLambda (tType "Int" []) (tType "Int" [])) (binopsExpr [ ( varExpr "x", "+" ) ] (strExpr "a")))
    ]


{-| A module holding one top-level definition `name`, with parameters `args`,
annotation `tipe` and body `body`.
-}
annotated : String -> String -> List Src.Pattern -> Src.Type -> Src.Expr -> Src.Module
annotated moduleName name args tipe body =
    makeModuleWithTypedDefs moduleName
        [ { name = name, args = args, tipe = tipe, body = body } ]



-- ============================================================================
-- CATEGORIES
-- ============================================================================


{-| A definition annotated `Int` whose body is an expression of each category,
so that the report names the kind of expression it found.
-}
categoryCases : List RejectedCase
categoryCases =
    [ fromSource "list under Int" (rejectedWithFragment "TYPE MISMATCH" "The body is a list of type:") "x : Int\nx = [ 1 ]\n"
    , fromSource "float under Int" (rejectedWithFragment "TYPE MISMATCH" "Note: Read <https://elm-lang.org/0.19.1/implicit-casts> to l") "x : Int\nx = 1.5\n"
    , fromSource "string under Int" (rejectedWithFragment "TYPE MISMATCH" "Hint: Want to convert a String into an Int? Use the String.t") "x : Int\nx = \"s\"\n"
    , fromSource "char under Int" (rejectedWithFragment "TYPE MISMATCH" "The body is a character of type:") "x : Int\nx = 'c'\n"
    , fromSource "if under Int" (rejectedWithFragment "TYPE MISMATCH" "Hint: Want to convert a String into an Int? Use the String.t") "x : Int\nx = if True then \"a\" else \"b\"\n"
    , fromSource "case under Int" (rejectedWithFragment "TYPE MISMATCH" "Hint: Want to convert a String into an Int? Use the String.t") "x : Int\nx =\n    case 1 of\n        _ ->\n            \"a\"\n"
    , fromSource "function call under Int" (rejectedWithFragment "TYPE MISMATCH" "This `not` call produces:") "x : Int\nx = not True\n"
    , fromSource "constructor call under Int" (rejectedWithFragment "TYPE MISMATCH" "This `Just` call produces:") "x : Int\nx = Just 1\n"
    , fromSource "operator call under String" (rejectedWithFragment "TYPE MISMATCH" "Hint: Try using String.fromInt to convert it to a string?") "x : String\nx = 1 + 2\n"
    , fromSource "lambda under Int" (rejectedWithFragment "TYPE MISMATCH" "The body is an anonymous function of type:") "x : Int\nx = \\a -> a\n"
    , fromSource "accessor under Int" (rejectedWithFragment "TYPE MISMATCH" "This .name field access function has type:") "x : Int\nx = .name\n"
    , fromSource "field access under Int" (rejectedWithFragment "TYPE MISMATCH" "Hint: Want to convert a String into an Int? Use the String.t") "r = { name = \"a\" }\n\nx : Int\nx = r.name\n"
    , fromSource "record under Int" (rejectedWithFragment "TYPE MISMATCH" "The body is a record of type:") "x : Int\nx = { a = 1 }\n"
    , fromSource "tuple under Int" (rejectedWithFragment "TYPE MISMATCH" "The body is a tuple of type:") "x : Int\nx = ( 1, 2 )\n"
    , fromSource "unit under Int" (rejectedWithFragment "TYPE MISMATCH" "The body is a unit value:") "x : Int\nx = ()\n"
    , fromSource "local under Int" (rejectedWithFragment "TYPE MISMATCH" "Hint: Want to convert a String into an Int? Use the String.t") "x : Int -> Int\nx n =\n    let\n        y = \"s\"\n    in\n    y\n"
    , fromSource "foreign under Int" (rejectedWithFragment "TYPE MISMATCH" "This `identity` value is a:") "x : Int\nx = identity\n"
    , fromSource "top-level under Int" (rejectedWithFragment "TYPE MISMATCH" "Hint: Want to convert a String into an Int? Use the String.t") "s = \"s\"\n\nx : Int\nx = s\n"
    , fromSource "constructor under Int" (rejectedWithFragment "TYPE MISMATCH" "This `Nothing` value is a:") "x : Int\nx = Nothing\n"
    , fromSource "if as an argument" (rejectedWithFragment "TYPE MISMATCH" "Hint: Only Int and Float values work as numbers.") "x = not (if True then 1 else 2)\n"
    , fromSource "case as an argument" (rejectedWithFragment "TYPE MISMATCH" "Hint: Only Int and Float values work as numbers.") "x =\n    not\n        (case 1 of\n            _ ->\n                2\n        )\n"
    , fromSource "lambda call as an argument" (rejectedWithFragment "TYPE MISMATCH" "Hint: Only Int and Float values work as numbers.") "x = not ((\\a -> a + 1) 1)\n"
    , fromSource "operator call as an argument" (rejectedWithFragment "TYPE MISMATCH" "Hint: Only Int and Float values work as numbers.") "x = not (1 + 2)\n"
    , fromSource "shader under Int" (rejectedWithFragment "TYPE MISMATCH" "shader") "x : Int\nx = [glsl| void main () {} |]\n"
    ]



-- ============================================================================
-- PROBLEMS
-- ============================================================================


{-| Mismatches for which the type diff finds a problem with its own hint:
casts between `Int`, `Float` and `String`, a `Bool` expected of another type,
a `Maybe` where its contents were expected, and functions of different arity.
-}
problemCases : List RejectedCase
problemCases =
    [ fromSource "Int where Float" (rejectedWithFragment "TYPE MISMATCH" "Note: Read <https://elm-lang.org/0.19.1/implicit-casts> to l") "n : Int\nn = 1\n\nx : Float\nx = n\n"
    , fromSource "Float where Int" (rejectedWithFragment "TYPE MISMATCH" "Note: Read <https://elm-lang.org/0.19.1/implicit-casts> to l") "f : Float\nf = 1.5\n\nx : Int\nx = f\n"
    , fromSource "Int where String" (rejectedWithFragment "TYPE MISMATCH" "Hint: Want to convert an Int into a String? Use the String.f") "n : Int\nn = 1\n\nx : String\nx = n\n"
    , fromSource "Float where String" (rejectedWithFragment "TYPE MISMATCH" "Hint: Want to convert a Float into a String? Use the String.") "f : Float\nf = 1.5\n\nx : String\nx = f\n"
    , fromSource "String where Int" (rejectedWithFragment "TYPE MISMATCH" "Hint: Want to convert a String into an Int? Use the String.t") "s : String\ns = \"1\"\n\nx : Int\nx = s\n"
    , fromSource "String where Float" (rejectedWithFragment "TYPE MISMATCH" "Hint: Want to convert a String into a Float? Use the String.") "s : String\ns = \"1\"\n\nx : Float\nx = s\n"
    , fromSource "String where Bool" (rejectedWithFragment "TYPE MISMATCH" "Hint: Elm does not have “truthiness” such that ints and stri") "s : String\ns = \"1\"\n\nx : Bool\nx = s\n"
    , fromSource "number where Bool" (rejectedWithFragment "TYPE MISMATCH" "Hint: Only Int and Float values work as numbers.") "x : Bool\nx = 1\n"
    , fromSource "number where String" (rejectedWithFragment "TYPE MISMATCH" "Hint: Try using String.fromInt to convert it to a string?") "x : String\nx = 1\n"
    , fromSource "Maybe Int where Int" (rejectedWithFragment "TYPE MISMATCH" "This `m` value is a:") "m : Maybe Int\nm = Just 1\n\nx : Int\nx = m\n"
    , fromSource "two-argument lambda where one" (rejectedWithFragment "TYPE MISMATCH" "Hint: It looks like it takes too many arguments. I see 1 ext") "f : Int -> Int\nf = \\a b -> a\n"
    , fromSource "one-argument function where two" (rejectedWithFragment "TYPE MISMATCH" "Hint: It looks like it takes too few arguments. I was expect") "g : Int -> Int\ng a = a\n\nf : Int -> Int -> Int\nf = g\n"
    , fromSource "same type constructor, different arguments" (rejectedWithFragment "TYPE MISMATCH" "Hint: Want to convert a String into an Int? Use the String.t") "x : Maybe Int\nx = Just \"a\"\n"
    , fromSource "tuple sizes differ" (rejectedWithFragment "TYPE MISMATCH" "The body is a tuple of type:") "x : ( Int, Int )\nx = ( 1, 2, 3 )\n"
    , fromSource "triples differ" (rejectedWithFragment "TYPE MISMATCH" "Hint: Want to convert a String into an Int? Use the String.t") "x : ( Int, Int, Int )\nx = ( 1, 2, \"a\" )\n"
    , fromSource "pairs differ" (rejectedWithFragment "TYPE MISMATCH" "Hint: Try using String.fromInt to convert it to a string?") "x : ( Int, String )\nx = ( 1, 2 )\n"
    , fromSource "functions differ in result" (rejectedWithFragment "TYPE MISMATCH" "Hint: Want to convert a String into an Int? Use the String.t") "g : Int -> String\ng a = \"a\"\n\nf : Int -> Int\nf = g\n"
    , fromSource "list of the wrong element" (rejectedWithFragment "TYPE MISMATCH" "Hint: Try using String.fromInt to convert it to a string?") "x : List String\nx = [ 1 ]\n"
    , fromSource "number and appendable list entries" (rejectedWithFragment "TYPE MISMATCH" "Hint: Everything in a list must be the same type of value. T") "f a b = [ a + 1, b ++ b ]\n"
    , fromSource "number and compappend list entries" (rejectedWithFragment "TYPE MISMATCH" "Hint: Everything in a list must be the same type of value. T") "f a b =\n    let\n        c = b ++ b\n    in\n    if c < c then [ a + 1, c ] else []\n"
    , fromSource "number and comparable list entries" (rejectedWithFragment "TYPE MISMATCH" "Hint: Everything in a list must be the same type of value. T") "f a b =\n    let\n        c = if b < b then b else b\n    in\n    [ a + 1, c, True ]\n"
    , fromSource "number list entry with a rigid var" (rejectedWithFragment "TYPE MISMATCH" "Hint: Everything in a list must be the same type of value. T") "f : a -> List a\nf x = [ x, 1 ]\n"
    , fromSource "number list entry with a rigid comparable" (rejectedWithFragment "TYPE MISMATCH" "Hint: Everything in a list must be the same type of value. T") "f : comparable -> List comparable\nf x = [ x, 1 ]\n"
    , fromSource "number list entry with a function" (rejectedWithFragment "TYPE MISMATCH" "Hint: Everything in a list must be the same type of value. T") "x = [ 1, not ]\n"
    , fromSource "number list entry with a record" (rejectedWithFragment "TYPE MISMATCH" "Hint: Everything in a list must be the same type of value. T") "x = [ 1, { a = 1 } ]\n"
    , fromSource "number list entry with a unit" (rejectedWithFragment "TYPE MISMATCH" "Hint: Everything in a list must be the same type of value. T") "x = [ 1, () ]\n"
    , fromSource "number list entry with a tuple" (rejectedWithFragment "TYPE MISMATCH" "Hint: Everything in a list must be the same type of value. T") "x = [ 1, ( 1, 2 ) ]\n"
    , fromSource "number list entry with a Bool" (rejectedWithFragment "TYPE MISMATCH" "Hint: Everything in a list must be the same type of value. T") "x = [ 1, True ]\n"
    , fromSource "number list entry with an alias" (rejectedWithFragment "TYPE MISMATCH" "Hint: Everything in a list must be the same type of value. T") "type alias N = { y : Int }\n\nn : N\nn = { y = 1 }\n\nx = [ 1, n ]\n"
    , fromSource "comparable list entry with a record" (rejectedWithFragment "TYPE MISMATCH" "Hint: Everything in a list must be the same type of value. T") "f a = [ (if a < a then a else a), { b = 1 } ]\n"
    , fromSource "comparable list entry with a Bool" (rejectedWithFragment "TYPE MISMATCH" "Hint: Everything in a list must be the same type of value. T") "f a = [ (if a < a then a else a), True ]\n"
    , fromSource "comparable list entry with a function" (rejectedWithFragment "TYPE MISMATCH" "Hint: Everything in a list must be the same type of value. T") "f a = [ (if a < a then a else a), not ]\n"
    , fromSource "appendable list entry with a Bool" (rejectedWithFragment "TYPE MISMATCH" "Hint: Everything in a list must be the same type of value. T") "f a = [ a ++ a, True ]\n"
    , fromSource "compappend list entry with a Bool" (rejectedWithFragment "TYPE MISMATCH" "Hint: Everything in a list must be the same type of value. T") "f a = [ (if a ++ a < a then a else a), True ]\n"
    , fromSource "rigid var as a non-record alias" (rejectedWithFragment "TYPE MISMATCH" "This `s` value is a:") "type alias S = String\n\ns : S\ns = \"a\"\n\nf : a -> a\nf x = s\n"
    , fromSource "rigid number as a non-record alias" (rejectedWithFragment "TYPE MISMATCH" "This `s` value is a:") "type alias S = String\n\ns : S\ns = \"a\"\n\nf : number -> number\nf x = s\n"
    , fromSource "rigid comparable as a Bool" (rejectedWithFragment "TYPE MISMATCH" "Hint: The `comparable` in your type annotation is saying tha") "f : comparable -> comparable\nf x = True\n"
    , fromSource "rigid appendable as a Bool" (rejectedWithFragment "TYPE MISMATCH" "Hint: The `appendable` in your type annotation is saying tha") "f : appendable -> appendable\nf x = True\n"
    , fromSource "rigid compappend as a Bool" (rejectedWithFragment "TYPE MISMATCH" "Hint: The `compappend` in your type annotation is saying tha") "f : compappend -> compappend\nf x = True\n"
    , fromSource "rigid comparable as a number" (rejectedWithFragment "TYPE MISMATCH" "Hint: The `comparable` in your type annotation is saying tha") "f : comparable -> comparable\nf x = 1\n"
    , fromSource "list of strings where list of ints" (rejectedWithFragment "TYPE MISMATCH" "Hint: Want to convert a String into an Int? Use the String.t") "s : List String\ns = []\n\nx : List Int\nx = s\n"
    , fromSource "list where Maybe" (rejectedWithFragment "TYPE MISMATCH" "This `s` value is a:") "s : List Int\ns = []\n\nx : Maybe Int\nx = s\n"
    , fromSource "Maybe where list" (rejectedWithFragment "TYPE MISMATCH" "This `Just` call produces:") "x : List Int\nx = Just 1\n"
    , fromSource "Maybe of the wrong type" (rejectedWithFragment "TYPE MISMATCH" "Hint: Want to convert a String into an Int? Use the String.t") "m : Maybe String\nm = Nothing\n\nx : Maybe Int\nx = m\n"
    , fromSource "same rigid var mismatch inside" (rejectedWithFragment "TYPE MISMATCH" "Hint: Your type annotation uses `b` and `a` as separate type") "f : a -> b -> ( a, a )\nf x y = ( x, y )\n"
    , fromSource "record where empty closed record" (rejectedWithFragment "TYPE MISMATCH" "The body is a record of type:") "x : {}\nx = { a = 1 }\n"
    , fromSource "closed record where extensible" (rejectedWithFragment "TYPE MISMATCH" "Hint: Looks like the age field is missing.") "g : { r | name : Int } -> { r | name : Int }\ng r = r\n\nx : { name : Int, age : Int }\nx = g { name = 1 }\n"
    , fromSource "extensible where closed record with an extra field" (rejectedWithFragment "TYPE MISMATCH" "Hint: Seems like a record field typo. Maybe age should be na") "g : { r | name : Int, age : Int } -> Int\ng r = r.name\n\nh : { name : Int } -> Int\nh r = g r\n"
    , fromSource "two extensible records" (rejectedWithFragment "TYPE MISMATCH" "Hint: Your type annotation uses `r` and `s` as separate type") "g : { r | name : Int } -> { s | name : Int }\ng r = r\n"
    , fromSource "extensible and flex record" (rejectedWithFragment "TYPE MISMATCH" "Hint: Want to convert a String into an Int? Use the String.t") "g : { r | name : Int } -> Int\ng r = r.name\n\nh a = g { a | name = \"s\" }\n"
    , fromSource "aliases of the same name in two modules" (rejectedWithFragment "TYPE MISMATCH" "Hint: Everything in a list must be the same type of value. T") "type Maybe a = Maybe a\n\nm : Maybe Int\nm = Maybe 1\n\nx : Basics.Int\nx = 1\n\ny = [ m, Just 1 ]\n"
    , fromSource "alias where alias of another" (rejectedWithFragment "TYPE MISMATCH" "This `p` value is a:") "type alias P = { a : Int }\n\ntype alias Q = { a : String }\n\np : P\np = { a = 1 }\n\nx : Q\nx = p\n"
    , fromSource "alias where a record" (rejectedWithFragment "TYPE MISMATCH" "Hint: Want to convert an Int into a String? Use the String.f") "type alias P = { a : Int }\n\np : P\np = { a = 1 }\n\nx : { a : String }\nx = p\n"
    , fromSource "alias where a type" (rejectedWithFragment "TYPE MISMATCH" "This `p` value is a:") "type alias P = Int\n\np : P\np = 1\n\nx : String\nx = p\n"
    , fromSource "type where an alias" (rejectedWithFragment "TYPE MISMATCH" "The body is a string of type:") "type alias P = Int\n\nx : P\nx = \"s\"\n"
    , fromSource "aliases of different names" (rejectedWithFragment "TYPE MISMATCH" "This `p` value is a:") "type alias P = Int\n\ntype alias Q = String\n\np : P\np = 1\n\nx : Q\nx = p\n"
    , fromSource "parameterised alias" (rejectedWithFragment "TYPE MISMATCH" "Hint: Want to convert an Int into a String? Use the String.f") "type alias Box a = { v : a }\n\nb : Box Int\nb = { v = 1 }\n\nx : Box String\nx = b\n"
    , fromSource "custom types of different names" (rejectedWithFragment "TYPE MISMATCH" "This `B` value is a:") "type A = A\n\ntype B = B\n\nx : A\nx = B\n"
    , fromSource "same custom type, different arguments" (rejectedWithFragment "TYPE MISMATCH" "Hint: Want to convert an Int into a String? Use the String.f") "type T a b = T a b\n\nt : T Int Int\nt = T 1 1\n\nx : T Int String\nx = t\n"
    , fromSource "list of a list" (rejectedWithFragment "TYPE MISMATCH" "Hint: Want to convert a String into an Int? Use the String.t") "x : List (List Int)\nx = [ [ \"a\" ] ]\n"
    , fromSource "unit where a type" (rejectedWithFragment "TYPE MISMATCH" "The body is a unit value:") "x : Int\nx = ()\n"
    , fromSource "tuple of lambdas" (rejectedWithFragment "TYPE MISMATCH" "Hint: It looks like it takes too many arguments. I see 1 ext") "x : ( Int -> Int, Int )\nx = ( \\a b -> a, 1 )\n"
    , fromSource "lambdas with the same arity differing" (rejectedWithFragment "TYPE MISMATCH" "Hint: Want to convert an Int into a String? Use the String.f") "g : Int -> Int -> String\ng a b = \"\"\n\nf : Int -> String -> String\nf = g\n"
    , fromSource "rigid vars that are the same" (rejectedWithFragment "TYPE MISMATCH" "Hint: Everything in a list must be the same type of value. T") "f : a -> List a\nf x = [ x, () ]\n"
    , fromSource "equal rigid supers" (rejectedWithFragment "TYPE MISMATCH" "Hint: Everything in a list must be the same type of value. T") "f : number -> number -> List number\nf x y = [ x, y, \"a\" ]\n"
    , fromSource "unknown element type printed" (rejectedWithFragment "TYPE MISMATCH" "List ?") "x =\n    let\n        l = [ 1, \"a\" ]\n    in\n    ( l, not l )\n"
    , fromSource "unknown type against a rigid var" (rejectedWithFragment "TYPE MISMATCH" "( Maybe number, ? )") "f : a -> ( Bool, a )\nf x =\n    case [ 1, \"a\" ] of\n        h :: _ ->\n            ( Just 1, h )\n\n        [] ->\n            ( True, x )\n"
    , fromSource "unknown type against a rigid number" (rejectedWithFragment "TYPE MISMATCH" "( Maybe number, ? )") "f : number -> ( Bool, number )\nf x =\n    case [ 1, \"a\" ] of\n        h :: _ ->\n            ( Just 1, h )\n\n        [] ->\n            ( True, x )\n"
    , fromSource "unknown type against a number" (rejectedWithFragment "TYPE MISMATCH" "?") "f x =\n    case [ 1, \"a\" ] of\n        h :: _ ->\n            ( Just 1, h )\n\n        [] ->\n            ( True, x + 1 )\n"
    , fromSource "unknown types on both sides" (rejectedWithFragment "TYPE MISMATCH" "( ?, String )") "x =\n    case [ 1, \"a\" ] of\n        h :: _ ->\n            [ ( h, 1 ), ( h, \"a\" ) ]\n\n        [] ->\n            []\n"
    , fromSource "self-applied argument against a rigid var" (rejectedWithFragment "TYPE MISMATCH" "∞") "h : a -> Int\nh w =\n    let\n        k x =\n            let\n                y = x x\n            in\n            [ x, \\v -> always 0 [ v, w ] ]\n    in\n    0\n"
    , fromSource "self-applied argument against a rigid number" (rejectedWithFragment "TYPE MISMATCH" "∞") "h : number -> Int\nh w =\n    let\n        k x =\n            let\n                y = x x\n            in\n            [ x, \\v -> always 0 [ v, w ] ]\n    in\n    0\n"
    , fromSource "self-applied argument against a number" (rejectedWithFragment "TYPE MISMATCH" "∞") "k x =\n    let\n        y = x x\n    in\n    [ x, \\v -> v + 1 ]\n"
    , fromSource "self-applied argument on both sides" (rejectedWithFragment "INFINITE TYPE" "∞") "k x =\n    let\n        y = x x\n    in\n    [ ( x, 1 ), ( x, \"a\" ) ]\n"
    , fromSource "same flex var on both sides" (rejectedWithFragment "TYPE MISMATCH" "( a, String )") "f x = [ ( x, 1 ), ( x, \"a\" ) ]\n"
    , fromSource "different flex vars" (rejectedWithFragment "TYPE MISMATCH" "Maybe a") "x = [ ( Nothing, 1 ), ( Nothing, \"a\" ) ]\n"
    , fromSource "units on both sides" (rejectedWithFragment "TYPE MISMATCH" "( (), String )") "x = [ ( (), 1 ), ( (), \"a\" ) ]\n"
    , fromSource "type against a flex var" (rejectedWithFragment "TYPE MISMATCH" "Maybe Bool") "x = [ ( Nothing, 1 ), ( Just True, \"a\" ) ]\n"
    , fromSource "Int against number" (rejectedWithFragment "TYPE MISMATCH" "( Int, String )") "n : Int\nn = 1\n\nx = [ ( 1, 1 ), ( n, \"a\" ) ]\n"
    , fromSource "list against a rigid var" (rejectedWithFragment "TYPE MISMATCH" "List a") "f : a -> a\nf x = [ x ]\n"
    , fromSource "rigid var against its list" (rejectedWithFragment "TYPE MISMATCH" "List a") "f : a -> List a\nf x = x\n"
    , fromSource "rigid var against its Maybe" (rejectedWithFragment "TYPE MISMATCH" "Maybe a") "f : a -> Maybe a\nf x = x\n"
    , fromSource "alias named like an imported type" (rejectedWithFragment "TYPE MISMATCH" "Test.Bool") "type alias Bool = Int\n\nb : Bool\nb = 1\n\ny = [ b, Basics.True ]\n"
    , fromSource "imported type named like an alias" (rejectedWithFragment "TYPE MISMATCH" "Test.Bool") "type alias Bool = Int\n\nb : Bool\nb = 1\n\ny = [ Basics.True, b ]\n"
    , fromSource "tuple against an alias" (rejectedWithFragment "TYPE MISMATCH" "N") "type alias N = Int\n\nm : N\nm = 1\n\ny = [ m, ( 1, 2 ) ]\n"
    , fromSource "comparable against a tuple" (rejectedWithFragment "TYPE MISMATCH" "comparable") "f a = if a < a then [ ( 1, a ), ( \"s\", ( 1, 2 ) ) ] else []\n"
    , fromSource "comparable against a record" (rejectedWithFragment "TYPE MISMATCH" "comparable") "f a = if a < a then [ ( 1, a ), ( \"s\", { b = 1 } ) ] else []\n"
    , fromSource "appendable against a tuple" (rejectedWithFragment "TYPE MISMATCH" "appendable") "f a = [ ( 1, a ++ a ), ( \"s\", ( 1, 2 ) ) ]\n"
    , fromSource "compappend against a tuple" (rejectedWithFragment "TYPE MISMATCH" "compappend") "f a = [ ( 1, if a ++ a < a then a else a ), ( \"s\", ( 1, 2 ) ) ]\n"
    , fromSource "rigid extension where closed" (rejectedWithFragment "TYPE MISMATCH" "{ r | name : Int }") "g : { r | name : Int } -> { name : Int }\ng r = r\n"
    , fromSource "rigid extension where flexible" (rejectedWithFragment "TYPE MISMATCH" "{ r | name : Int }") "h a = a.name ++ \"s\"\n\ng : { r | name : Int } -> String\ng r = h r\n"
    , fromSource "same rigid extension" (rejectedWithFragment "TYPE MISMATCH" "{ r | name : String }") "g : { r | name : Int } -> { r | name : String }\ng r = r\n"
    , fromSource "flexible record with an extra field where closed" (rejectedWithFragment "TYPE MISMATCH" "age") "g : { name : Int } -> Int\ng r = r.name\n\nh a =\n    let\n        z = a.age\n    in\n    g a\n"
    , fromSource "flexible record with a wrong field where closed" (rejectedWithFragment "TYPE MISMATCH" "name") "g : { name : Int } -> Int\ng r = r.name\n\nh a =\n    let\n        z = a.name ++ \"s\"\n    in\n    g a\n"
    , fromSource "closed record where flexible" (rejectedWithFragment "TYPE MISMATCH" "name") "h a = a.name ++ \"s\"\n\nx = h { name = 1 }\n"
    , fromSource "two flexible records" (rejectedWithFragment "TYPE MISMATCH" "name") "h a = a.name ++ \"s\"\n\nk c =\n    let\n        z = c.name + 1\n    in\n    h c\n"
    , fromSource "compappend against a rigid var" (rejectedWithFragment "TYPE MISMATCH" "compappend") "f : a -> Int\nf x = always 0 (\\b -> if b ++ b < b then [ x, b ] else [])\n"
    , fromSource "two comparable vars" (rejectedWithFragment "TYPE MISMATCH" "comparable") "type A = A\n\ntype B = B\n\nf a b = if a < a && b < b then [ ( A, a ), ( B, b ) ] else []\n"
    , fromSource "two flex vars after a mismatch" (rejectedWithFragment "TYPE MISMATCH" "Maybe a") "x = [ ( 1, Nothing ), ( \"a\", Nothing ) ]\n"
    , fromSource "Int against number after a mismatch" (rejectedWithFragment "TYPE MISMATCH" "( String, Int )") "n : Int\nn = 1\n\nx = [ ( 1, 1 ), ( \"a\", n ) ]\n"
    , fromSource "Maybe of a number against a rigid var" (rejectedWithFragment "TYPE MISMATCH" "Maybe number") "f : a -> a\nf x = Just 1\n"
    , fromSource "flexible record where closed after a mismatch" (rejectedWithFragment "TYPE MISMATCH" "name : String") "g : ( Int, { name : Int } ) -> Int\ng p = 0\n\nh a =\n    let\n        z = a.name ++ \"s\"\n    in\n    g ( \"s\", a )\n"
    , fromSource "closed record where flexible after a mismatch" (rejectedWithFragment "TYPE MISMATCH" "name : number") "f a =\n    let\n        z = a.name ++ \"s\"\n    in\n    [ ( 1, a ), ( \"s\", { name = 1 } ) ]\n"
    , fromSource "rigid extension where flexible after a mismatch" (rejectedWithFragment "TYPE MISMATCH" "{ r | name : Int }") "g : { r | name : Int } -> Int\ng r =\n    let\n        h a =\n            let\n                z = a.name ++ \"s\"\n            in\n            [ ( 1, a ), ( \"s\", r ) ]\n    in\n    0\n"
    , fromSource "differently named comparable vars" (rejectedWithFragment "TYPE MISMATCH" "comparable2") "type A = A\n\ntype B = B\n\nlex : comparable -> comparable\nlex v = v\n\nlex2 : comparable2 -> comparable2\nlex2 v = v\n\nx = [ ( A, lex ), ( B, lex2 ) ]\n"
    , fromSource "differently named flex vars" (rejectedWithFragment "TYPE MISMATCH" "b -> b") "type A = A\n\ntype B = B\n\nid1 : a -> a\nid1 v = v\n\nid2 : b -> b\nid2 v = v\n\nx = [ ( A, id1 ), ( B, id2 ) ]\n"
    ]



-- ============================================================================
-- CONTEXTS
-- ============================================================================


{-| Mismatches whose expected type comes from the surrounding expression: a
list entry, a negation, an `if` condition or branch, a `case` branch, a call's
arity or argument, a field access, a record update and a destructuring `let`,
and the branches and body of an annotated definition.
-}
contextCases : List RejectedCase
contextCases =
    [ fromSource "typed if branch" (rejectedWithFragment "TYPE MISMATCH" "Hint: Want to convert a String into an Int? Use the String.t") "f : Int -> Int\nf n = if True then n else \"s\"\n"
    , fromSource "typed case branch" (rejectedWithFragment "TYPE MISMATCH" "Hint: Want to convert a String into an Int? Use the String.t") "f : Int -> Int\nf n =\n    case n of\n        0 ->\n            1\n\n        _ ->\n            \"s\"\n"
    , fromSource "list entry" (rejectedWithFragment "TYPE MISMATCH" "Hint: Everything in a list must be the same type of value. T") "x = [ 1, 2, \"a\" ]\n"
    , fromSource "second list entry" (rejectedWithFragment "TYPE MISMATCH" "Hint: Everything in a list must be the same type of value. T") "x = [ \"a\", 1 ]\n"
    , fromSource "negate" (rejectedWithFragment "TYPE MISMATCH" "Hint: Try using String.toInt to convert it to an integer?") "s = \"s\"\n\nx = -s\n"
    , fromSource "if condition int" (rejectedWithFragment "TYPE MISMATCH" "Hint: Only Int and Float values work as numbers.") "x = if 1 then 2 else 3\n"
    , fromSource "if condition string" (rejectedWithFragment "TYPE MISMATCH" "Hint: Elm does not have “truthiness” such that ints and stri") "s = \"s\"\n\nx = if s then 2 else 3\n"
    , fromSource "if branch" (rejectedWithFragment "TYPE MISMATCH" "Hint: All branches in an `if` must produce the same type of") "x = if True then 1 else \"a\"\n"
    , fromSource "third if branch" (rejectedWithFragment "TYPE MISMATCH" "Hint: All branches in an `if` must produce the same type of") "x = if True then 1 else if False then 2 else \"a\"\n"
    , fromSource "case branch" (rejectedWithFragment "TYPE MISMATCH" "Hint: All branches in a `case` must produce the same type of") "x =\n    case 1 of\n        1 ->\n            \"a\"\n\n        _ ->\n            2\n"
    , fromSource "third case branch" (rejectedWithFragment "TYPE MISMATCH" "Hint: All branches in a `case` must produce the same type of") "x =\n    case 1 of\n        1 ->\n            \"a\"\n\n        2 ->\n            \"b\"\n\n        _ ->\n            2\n"
    , fromSource "too many arguments to a function" (rejectedWithFragment "TOO MANY ARGS" "The `not` function expects 1 argument, but it got 2 instead.") "x = not True False\n"
    , fromSource "too many arguments to a local" (rejectedWithFragment "TOO MANY ARGS" "The `y` value is not a function, but it was given 1 argument") "y = 5\n\nx = y 1\n"
    , fromSource "too many arguments to a constructor" (rejectedWithFragment "TOO MANY ARGS" "The `Just` constructor expects 1 argument, but it got 2 inst") "x = Just 1 2\n"
    , fromSource "too many arguments to an expression" (rejectedWithFragment "TYPE MISMATCH" "Hint: Only Int and Float values work as numbers.") "x = (\\a -> a) 1 2\n"
    , fromSource "too many arguments to a literal" (rejectedWithFragment "TOO MANY ARGS" "This value is not a function, but it was given 1 argument.") "x = 1 2\n"
    , fromSource "argument to a function" (rejectedWithFragment "TYPE MISMATCH" "Hint: Only Int and Float values work as numbers.") "x = not 1\n"
    , fromSource "second argument to a function" (rejectedWithFragment "TYPE MISMATCH" "Hint: I always figure out the argument types from left to ri") "f : Int -> String -> Int\nf a b = a\n\nx = f 1 2\n"
    , fromSource "argument to a constructor" (rejectedWithFragment "TYPE MISMATCH" "Hint: Want to convert a String into an Int? Use the String.t") "type T = T Int\n\nx = T \"s\"\n"
    , fromSource "argument to a lambda" (rejectedWithFragment "TYPE MISMATCH" "Hint: Try using String.toInt to convert it to an integer?") "x = (\\a -> a + 1) \"s\"\n"
    , fromSource "argument to an operator function" (rejectedWithFragment "TYPE MISMATCH" "Hint: Try using String.toInt to convert it to an integer?") "x = (+) \"a\" 1\n"
    , fromSource "field typo" (rejectedWithFragment "TYPE MISMATCH" "This is usually a typo. Here are the `r` fields that are mos") "r = { name = \"a\" }\n\nx = r.nmae\n"
    , fromSource "missing field" (rejectedWithFragment "TYPE MISMATCH" "This is usually a typo. Here are the fields that are most si") "x = { a = 1 }.zzzz\n"
    , fromSource "access on a number" (rejectedWithFragment "TYPE MISMATCH" "This `n` value is a:") "n : Int\nn = 1\n\nx = n.foo\n"
    , fromSource "update of a missing field" (rejectedWithFragment "TYPE MISMATCH" "This is usually a typo. Here are the record fields that are") "r = { x = 1 }\n\ny = { r | z = 2 }\n"
    , fromSource "update of a near field" (rejectedWithFragment "TYPE MISMATCH" "This is usually a typo. Here are the record fields that are") "r = { count = 1 }\n\ny = { r | cuont = 2 }\n"
    , fromSource "update of two missing fields" (rejectedWithFragment "TYPE MISMATCH" "This is usually a typo. Here are the record fields that are") "r = { x = 1 }\n\ny = { r | z = 2, w = 3 }\n"
    , fromSource "update value" (rejectedWithFragment "TYPE MISMATCH" "Note: The record update syntax does not allow you to change") "f : { x : Int } -> { x : Int }\nf r = { r | x = \"s\" }\n"
    , fromSource "destructure" (rejectedWithFragment "TYPE MISMATCH" "Hint: Only Int and Float values work as numbers.") "x =\n    let\n        ( a, b ) = 1\n    in\n    a\n"
    , fromSource "too many arguments to a nullary constructor" (rejectedWithFragment "TOO MANY ARGS" "The `T` value is not a function, but it was given 1 argument") "type T = T\n\nx = T 1\n"
    , fromSource "too many arguments to an operator" (rejectedWithFragment "TOO MANY ARGS" "The (+) operator expects 2 arguments, but it got 3 instead.") "x = (+) 1 2 3\n"
    , fromSource "too many arguments to a lambda" (rejectedWithFragment "TOO MANY ARGS" "This function expects 1 argument, but it got 2 instead.") "x = (\\a -> a + 1) 1 2\n"
    , fromSource "access on an empty record" (rejectedWithFragment "TYPE MISMATCH" "This `r` record does not have a `foo` field:") "r = {}\n\nx = r.foo\n"
    , fromSource "update of a number" (rejectedWithFragment "TYPE MISMATCH" "This `n` value is a:") "n : Int\nn = 1\n\ny = { n | x = 1 }\n"
    , fromSource "update of an empty record" (rejectedWithFragment "TYPE MISMATCH" "The record does not have a `x` field:") "r = {}\n\ny = { r | x = 1 }\n"
    ]



-- ============================================================================
-- OPERATORS
-- ============================================================================


{-| Mismatches on either side of an operator, including those with their own
explanations: arithmetic, boolean, comparison, equality, append, cons, pipes
and composition.
-}
operatorCases : List RejectedCase
operatorCases =
    [ fromSource "string left of +" (rejectedWithFragment "TYPE MISMATCH" "Hint: Switch to the (++) operator to append strings!") "x = \"a\" + 1\n"
    , fromSource "string right of +" (rejectedWithFragment "TYPE MISMATCH" "Hint: Switch to the (++) operator to append strings!") "x = 1 + \"a\"\n"
    , fromSource "lists added" (rejectedWithFragment "TYPE MISMATCH" "Hint: Switch to the (++) operator to append lists!") "x = [ 1 ] + [ 2 ]\n"
    , fromSource "list multiplied" (rejectedWithFragment "TYPE MISMATCH" "Hint: Maybe you want List.repeat to build a list of repeated") "x = [ 1 ] * 2\n"
    , fromSource "string right of -" (rejectedWithFragment "TYPE MISMATCH" "Hint: Try using String.toInt to convert it to an integer?") "x = 1 - \"a\"\n"
    , fromSource "string right of *" (rejectedWithFragment "TYPE MISMATCH" "Hint: Try using String.toInt to convert it to an integer?") "x = 1 * \"a\"\n"
    , fromSource "string right of ^" (rejectedWithFragment "TYPE MISMATCH" "Hint: Try using String.toInt to convert it to an integer?") "x = 2 ^ \"a\"\n"
    , fromSource "Int left of /" (rejectedWithFragment "TYPE MISMATCH" "Note: Read <https://elm-lang.org/0.19.1/implicit-casts> to l") "n : Int\nn = 1\n\nx = n / 2\n"
    , fromSource "Int right of /" (rejectedWithFragment "TYPE MISMATCH" "Note: Read <https://elm-lang.org/0.19.1/implicit-casts> to l") "n : Int\nn = 1\n\nx = 2 / n\n"
    , fromSource "Float left of //" (rejectedWithFragment "TYPE MISMATCH" "Note: Read <https://elm-lang.org/0.19.1/implicit-casts> to l") "x = 1.5 // 2\n"
    , fromSource "Float right of //" (rejectedWithFragment "TYPE MISMATCH" "Note: Read <https://elm-lang.org/0.19.1/implicit-casts> to l") "x = 2 // 1.5\n"
    , fromSource "number right of &&" (rejectedWithFragment "TYPE MISMATCH" "Hint: Only Int and Float values work as numbers.") "x = True && 1\n"
    , fromSource "number left of ||" (rejectedWithFragment "TYPE MISMATCH" "Hint: Only Int and Float values work as numbers.") "x = 1 || True\n"
    , fromSource "string right of <" (rejectedWithFragment "TYPE MISMATCH" "Hint: Try using String.fromInt to convert it to a string?") "x = 1 < \"a\"\n"
    , fromSource "string left of <" (rejectedWithFragment "TYPE MISMATCH" "Hint: Try using String.toInt to convert it to an integer?") "x = \"a\" < 1\n"
    , fromSource "Bools compared" (rejectedWithFragment "TYPE MISMATCH" "Hint: I do not know how to compare `Bool` values. I can only") "x = True < False\n"
    , fromSource "records compared" (rejectedWithFragment "TYPE MISMATCH" "Hint: I do not know how to compare records. I can only compa") "x = { a = 1 } < { a = 2 }\n"
    , fromSource "functions compared" (rejectedWithFragment "TYPE MISMATCH" "Hint: I only know how to compare ints, floats, chars, string") "x = not < not\n"
    , fromSource "string right of >=" (rejectedWithFragment "TYPE MISMATCH" "Hint: Try using String.fromInt to convert it to a string?") "x = 1 >= \"a\"\n"
    , fromSource "string right of ==" (rejectedWithFragment "TYPE MISMATCH" "Hint: Try using String.fromInt to convert it to a string?") "x = 1 == \"a\"\n"
    , fromSource "string right of /=" (rejectedWithFragment "TYPE MISMATCH" "Hint: Try using String.fromInt to convert it to a string?") "x = 1 /= \"a\"\n"
    , fromSource "Int left of ++" (rejectedWithFragment "TYPE MISMATCH" "The (++) operator can append List and String values, but not") "n : Int\nn = 1\n\nx = n ++ \"a\"\n"
    , fromSource "Int right of ++" (rejectedWithFragment "TYPE MISMATCH" "I thought I was appending String values here, not Int values") "n : Int\nn = 1\n\nx = \"a\" ++ n\n"
    , fromSource "lists of different types appended" (rejectedWithFragment "TYPE MISMATCH" "Hint: Try using String.fromInt to convert it to a string?") "x = [ 1 ] ++ [ \"a\" ]\n"
    , fromSource "string appended to list" (rejectedWithFragment "TYPE MISMATCH" "The (++) operator needs the same type of value on both sides") "x = [ 1 ] ++ \"a\"\n"
    , fromSource "number right of ::" (rejectedWithFragment "TYPE MISMATCH" "Hint: Only Int and Float values work as numbers.") "x = 1 :: 2\n"
    , fromSource "string left of ::" (rejectedWithFragment "TYPE MISMATCH" "Hint: Try using String.toInt to convert it to an integer?") "x = \"a\" :: [ 1 ]\n"
    , fromSource "number piped into a number" (rejectedWithFragment "TYPE MISMATCH" "Hint: Only Int and Float values work as numbers.") "x = 1 |> 2\n"
    , fromSource "number into not with <|" (rejectedWithFragment "TYPE MISMATCH" "Hint: Only Int and Float values work as numbers.") "x = not <| 1\n"
    , fromSource "number piped into not" (rejectedWithFragment "TYPE MISMATCH" "Hint: Only Int and Float values work as numbers.") "x = 1 |> not\n"
    , fromSource "composed with a number" (rejectedWithFragment "TYPE MISMATCH" "Hint: With operators like (>>) I always check the left side") "x = not >> 1\n"
    , fromSource "composed backwards with a number" (rejectedWithFragment "TYPE MISMATCH" "Hint: With operators like (<<) I always check the left side") "x = not << 1\n"
    , fromSource "number plus appendable" (rejectedWithFragment "TYPE MISMATCH" "The (++) operator can append List and String values, but not") "g a b = (a + 1) ++ b\n"
    , fromSource "Int right of + with Float" (rejectedWithFragment "TYPE MISMATCH" "Note: Read <https://elm-lang.org/0.19.1/implicit-casts> to l") "f : Float\nf = 1.5\n\nn : Int\nn = 1\n\nx = f + n\n"
    , fromSource "Float right of + with Int" (rejectedWithFragment "TYPE MISMATCH" "Note: Read <https://elm-lang.org/0.19.1/implicit-casts> to l") "f : Float\nf = 1.5\n\nn : Int\nn = 1\n\nx = n + f\n"
    , fromSource "Int right of * with Float" (rejectedWithFragment "TYPE MISMATCH" "Note: Read <https://elm-lang.org/0.19.1/implicit-casts> to l") "f : Float\nf = 1.5\n\nn : Int\nn = 1\n\nx = f * n\n"
    , fromSource "Float right of * with Int" (rejectedWithFragment "TYPE MISMATCH" "Note: Read <https://elm-lang.org/0.19.1/implicit-casts> to l") "f : Float\nf = 1.5\n\nn : Int\nn = 1\n\nx = n * f\n"
    , fromSource "Int right of - with Float" (rejectedWithFragment "TYPE MISMATCH" "Note: Read <https://elm-lang.org/0.19.1/implicit-casts> to l") "f : Float\nf = 1.5\n\nn : Int\nn = 1\n\nx = f - n\n"
    , fromSource "Float right of - with Int" (rejectedWithFragment "TYPE MISMATCH" "Note: Read <https://elm-lang.org/0.19.1/implicit-casts> to l") "f : Float\nf = 1.5\n\nn : Int\nn = 1\n\nx = n - f\n"
    , fromSource "Int right of ^ with Float" (rejectedWithFragment "TYPE MISMATCH" "Note: Read <https://elm-lang.org/0.19.1/implicit-casts> to l") "f : Float\nf = 1.5\n\nn : Int\nn = 1\n\nx = f ^ n\n"
    , fromSource "Float right of ^ with Int" (rejectedWithFragment "TYPE MISMATCH" "Note: Read <https://elm-lang.org/0.19.1/implicit-casts> to l") "f : Float\nf = 1.5\n\nn : Int\nn = 1\n\nx = n ^ f\n"
    , fromSource "list right of +" (rejectedWithFragment "TYPE MISMATCH" "Hint: Switch to the (++) operator to append lists!") "x = 1 + [ 2 ]\n"
    , fromSource "Bool right of +" (rejectedWithFragment "TYPE MISMATCH" "Hint: Only Int and Float values work as numbers.") "x = 1 + True\n"
    , fromSource "list right of *" (rejectedWithFragment "TYPE MISMATCH" "Hint: Maybe you want List.repeat to build a list of repeated") "x = 2 * [ 1 ]\n"
    , fromSource "Bool left of -" (rejectedWithFragment "TYPE MISMATCH" "Hint: Only Int and Float values work as numbers.") "x = True - 1\n"
    , fromSource "Bool left of ^" (rejectedWithFragment "TYPE MISMATCH" "Hint: Only Int and Float values work as numbers.") "x = True ^ 2\n"
    , fromSource "Bool left of *" (rejectedWithFragment "TYPE MISMATCH" "Hint: Only Int and Float values work as numbers.") "x = True * 2\n"
    , fromSource "number left of &&" (rejectedWithFragment "TYPE MISMATCH" "Hint: Only Int and Float values work as numbers.") "x = 1 && True\n"
    , fromSource "number right of ||" (rejectedWithFragment "TYPE MISMATCH" "Hint: Only Int and Float values work as numbers.") "x = True || 1\n"
    , fromSource "function left of >" (rejectedWithFragment "TYPE MISMATCH" "Hint: I only know how to compare ints, floats, chars, string") "x = not > not\n"
    , fromSource "record left of <=" (rejectedWithFragment "TYPE MISMATCH" "Hint: I do not know how to compare records. I can only compa") "x = { a = 1 } <= { a = 1 }\n"
    , fromSource "unit left of >=" (rejectedWithFragment "TYPE MISMATCH" "Hint: I only know how to compare ints, floats, chars, string") "x = () >= ()\n"
    , fromSource "string right of >" (rejectedWithFragment "TYPE MISMATCH" "Hint: Try using String.fromInt to convert it to a string?") "x = 1 > \"a\"\n"
    , fromSource "string right of <=" (rejectedWithFragment "TYPE MISMATCH" "Hint: Try using String.fromInt to convert it to a string?") "x = 1 <= \"a\"\n"
    , fromSource "number left of <|" (rejectedWithFragment "TYPE MISMATCH" "Hint: Only Int and Float values work as numbers.") "x = 1 <| 2\n"
    , fromSource "number left of >>" (rejectedWithFragment "TYPE MISMATCH" "Hint: Only Int and Float values work as numbers.") "x = 1 >> not\n"
    , fromSource "String left of /" (rejectedWithFragment "TYPE MISMATCH" "Hint: Want to convert a String into a Float? Use the String.") "x = \"a\" / 2\n"
    , fromSource "String left of //" (rejectedWithFragment "TYPE MISMATCH" "Hint: Want to convert a String into an Int? Use the String.t") "x = \"a\" // 2\n"
    , fromSource "Float compared for equality" (rejectedWithFragment "TYPE MISMATCH" "Note: Equality on floats is not 100% reliable due to the des") "x = 1.5 == \"a\"\n"
    , fromSource "Float left of ++" (rejectedWithFragment "TYPE MISMATCH" "The (++) operator can append List and String values, but not") "f : Float\nf = 1.5\n\nx = f ++ \"a\"\n"
    , fromSource "Bool left of ++" (rejectedWithFragment "TYPE MISMATCH" "Hint: I only know how to append strings and lists.") "x = True ++ \"a\"\n"
    , fromSource "Int right of ++ with a list" (rejectedWithFragment "TYPE MISMATCH" "I thought I was appending List values here, not Int values l") "n : Int\nn = 1\n\nx = [ 1 ] ++ n\n"
    , fromSource "list right of ++ with a string" (rejectedWithFragment "TYPE MISMATCH" "The (++) operator needs the same type of value on both sides") "x = \"a\" ++ [ 1 ]\n"
    , fromSource "string right of ++ with a list" (rejectedWithFragment "TYPE MISMATCH" "The (++) operator needs the same type of value on both sides") "x = [ 1 ] ++ \"a\"\n"
    , fromSource "Bool right of ++ with a string" (rejectedWithFragment "TYPE MISMATCH" "Hint: Elm does not have “truthiness” such that ints and stri") "x = \"a\" ++ True\n"
    , fromSource "list consed onto a list of strings" (rejectedWithFragment "TYPE MISMATCH" "Hint: Are you trying to append two lists? The (++) operator") "x = [ 1 ] :: [ \"a\" ]\n"
    , fromSource "Bool consed onto a list of strings" (rejectedWithFragment "TYPE MISMATCH" "The left side of (::) is:") "x = True :: [ \"a\" ]\n"
    , fromSource "consed onto a Bool" (rejectedWithFragment "TYPE MISMATCH" "This `True` value is a:") "x = 1 :: True\n"
    , fromSource "Maybe consed onto a list of strings" (rejectedWithFragment "TYPE MISMATCH" "Lists need ALL elements to be the same type though.") "x = Just 1 :: [ \"a\" ]\n"
    , fromSource "consed onto a Maybe" (rejectedWithFragment "TYPE MISMATCH" "The (::) operator can only add elements onto lists.") "x = 1 :: Just 1\n"
    ]



-- ============================================================================
-- TYPE VARIABLES
-- ============================================================================


{-| Annotations whose type variables, plain or constrained (`number`,
`comparable`, `appendable`, `compappend`), the body does not respect.
-}
rigidCases : List RejectedCase
rigidCases =
    [ fromSource "rigid var returned as Int" (rejectedWithFragment "TYPE MISMATCH" "Hint: Your type annotation uses type variable `a` which mean") "f : a -> Int\nf x = x\n"
    , fromSource "two rigid vars" (rejectedWithFragment "TYPE MISMATCH" "Hint: Your type annotation uses `a` and `b` as separate type") "f : a -> b\nf x = x\n"
    , fromSource "rigid number as String" (rejectedWithFragment "TYPE MISMATCH" "Hint: The `number` in your type annotation is saying that in") "f : number -> String\nf x = x\n"
    , fromSource "rigid comparable as number" (rejectedWithFragment "TYPE MISMATCH" "Hint: Your type annotation uses `comparable` and `number` as") "f : comparable -> number\nf x = x\n"
    , fromSource "rigid appendable as Int" (rejectedWithFragment "TYPE MISMATCH" "Hint: The `appendable` in your type annotation is saying tha") "f : appendable -> Int\nf x = x\n"
    , fromSource "rigid compappend as Int" (rejectedWithFragment "TYPE MISMATCH" "Hint: The `compappend` in your type annotation is saying tha") "f : compappend -> Int\nf x = x\n"
    , fromSource "rigid var added" (rejectedWithFragment "TYPE MISMATCH" "Hint: Your type annotation uses type variable `a` which mean") "f : a -> a\nf x = x + 1\n"
    , fromSource "rigid var as function" (rejectedWithFragment "TYPE MISMATCH" "Hint: Your type annotation uses type variable `a` which mean") "f : a -> a\nf x = \\y -> y\n"
    , fromSource "rigid var as record" (rejectedWithFragment "TYPE MISMATCH" "Hint: Your type annotation uses type variable `a` which mean") "f : a -> a\nf x = { y = 1 }\n"
    , fromSource "rigid var as unit" (rejectedWithFragment "TYPE MISMATCH" "Hint: Your type annotation uses type variable `a` which mean") "f : a -> a\nf x = ()\n"
    , fromSource "rigid var as tuple" (rejectedWithFragment "TYPE MISMATCH" "Hint: Your type annotation uses type variable `a` which mean") "f : a -> a\nf x = ( 1, 2 )\n"
    , fromSource "rigid var as Maybe" (rejectedWithFragment "TYPE MISMATCH" "Hint: Use Maybe.withDefault to handle possible errors. Longe") "f : a -> a\nf x = Just x\n"
    , fromSource "rigid var as alias" (rejectedWithFragment "TYPE MISMATCH" "This `p` value is a:") "type alias P = { y : Int }\n\np : P\np = { y = 1 }\n\nf : a -> a\nf x = p\n"
    , fromSource "rigid number as function" (rejectedWithFragment "TYPE MISMATCH" "Hint: The `number` in your type annotation is saying that in") "f : number -> number\nf x = \\y -> y\n"
    , fromSource "rigid number as record" (rejectedWithFragment "TYPE MISMATCH" "Hint: The `number` in your type annotation is saying that in") "f : number -> number\nf x = { y = 1 }\n"
    , fromSource "rigid number as unit" (rejectedWithFragment "TYPE MISMATCH" "Hint: The `number` in your type annotation is saying that in") "f : number -> number\nf x = ()\n"
    , fromSource "rigid number as tuple" (rejectedWithFragment "TYPE MISMATCH" "Hint: The `number` in your type annotation is saying that in") "f : number -> number\nf x = ( 1, 2 )\n"
    , fromSource "rigid number as Maybe" (rejectedWithFragment "TYPE MISMATCH" "Hint: Use Maybe.withDefault to handle possible errors. Longe") "f : number -> number\nf x = Just x\n"
    , fromSource "rigid number as alias" (rejectedWithFragment "TYPE MISMATCH" "This `p` value is a:") "type alias P = { y : Int }\n\np : P\np = { y = 1 }\n\nf : number -> number\nf x = p\n"
    , fromSource "rigid number as rigid var" (rejectedWithFragment "TYPE MISMATCH" "Hint: Your type annotation uses `a` and `number` as separate") "f : number -> a -> number\nf x y = y\n"
    , fromSource "rigid var as rigid number" (rejectedWithFragment "TYPE MISMATCH" "Hint: Your type annotation uses `number` and `a` as separate") "f : a -> number -> a\nf x y = y\n"
    , fromSource "rigid var appended" (rejectedWithFragment "TYPE MISMATCH" "Hint: Your type annotation uses type variable `a` which mean") "f : a -> a\nf x = x ++ x\n"
    , fromSource "rigid var compared" (rejectedWithFragment "TYPE MISMATCH" "Hint: Your type annotation uses type variable `a` which mean") "f : a -> Bool\nf x = x < x\n"
    , fromSource "rigid number appended" (rejectedWithFragment "TYPE MISMATCH" "Hint: The `number` in your type annotation is saying that in") "f : number -> number\nf x = x ++ x\n"
    , fromSource "rigid appendable added" (rejectedWithFragment "TYPE MISMATCH" "Hint: The `appendable` in your type annotation is saying tha") "f : appendable -> appendable\nf x = x + x\n"
    , fromSource "rigid var in a record extension" (rejectedWithFragment "TYPE MISMATCH" "Hint: Your type annotation uses `a` and `b` as separate type") "f : { a | x : Int } -> { b | x : Int }\nf r = r\n"
    ]



-- ============================================================================
-- RECORDS
-- ============================================================================


{-| Records whose fields differ from the ones an annotation asks for: a typo,
missing fields, extra fields, a field of the wrong type, and records with an
extension variable.
-}
recordFieldCases : List RejectedCase
recordFieldCases =
    [ fromSource "record field typo" (rejectedWithFragment "TYPE MISMATCH" "Hint: Seems like a record field typo. Maybe nmae should be n") "f : { name : Int } -> Int\nf r = r.name\n\nx = f { nmae = 1 }\n"
    , fromSource "record field missing" (rejectedWithFragment "TYPE MISMATCH" "Hint: Looks like the age field is missing.") "f : { name : Int, age : Int } -> Int\nf r = r.name\n\nx = f { name = 1 }\n"
    , fromSource "record fields missing" (rejectedWithFragment "TYPE MISMATCH" "Hint: Looks like fields age and size are missing.") "f : { name : Int, age : Int, size : Int } -> Int\nf r = r.name\n\nx = f { name = 1 }\n"
    , fromSource "record field extra" (rejectedWithFragment "TYPE MISMATCH" "Hint: Seems like a record field typo. Maybe age should be na") "f : { name : Int } -> Int\nf r = r.name\n\nx = f { name = 1, age = 2 }\n"
    , fromSource "record field of the wrong type" (rejectedWithFragment "TYPE MISMATCH" "Hint: Want to convert a String into an Int? Use the String.t") "x : { name : Int, age : Int }\nx = { name = 1, age = \"a\" }\n"
    , fromSource "extensible record given a closed one" (rejectedWithFragment "TYPE MISMATCH" "The body is a record of type:") "g : { r | name : Int } -> { r | name : Int }\ng r = { name = 1 }\n"
    , fromSource "extensible record missing a field" (rejectedWithFragment "TYPE MISMATCH" "Hint: Seems like a record field typo. Maybe name should be a") "g : { r | name : Int } -> Int\ng r = r.name\n\nx = g { age = 1 }\n"
    , fromSource "extensible record with a wrong field" (rejectedWithFragment "TYPE MISMATCH" "Hint: Want to convert a String into an Int? Use the String.t") "g : { r | name : Int } -> Int\ng r = r.name\n\nx = g { name = \"a\", age = 1 }\n"
    , fromSource "empty record where one with fields" (rejectedWithFragment "TYPE MISMATCH" "Hint: Looks like the name field is missing.") "x : { name : Int }\nx = {}\n"
    , fromSource "aliased record field of the wrong type" (rejectedWithFragment "TYPE MISMATCH" "Hint: Want to convert a String into an Int? Use the String.t") "type alias P = { a : Int }\n\nx : P\nx = { a = \"s\" }\n"
    , fromSource "two aliased records" (rejectedWithFragment "TYPE MISMATCH" "This `p` value is a:") "type alias P = { a : Int }\n\ntype alias Q = { b : Int }\n\np : P\np = { a = 1 }\n\nx : Q\nx = p\n"
    ]



-- ============================================================================
-- PATTERNS
-- ============================================================================


{-| Patterns that do not match the type they are given: in an annotated
function's arguments, in each position of a `case`, inside a constructor, a
list or after `::`, and in a lambda's arguments, with patterns of every
category.
-}
patternMismatchCases : List RejectedCase
patternMismatchCases =
    [ fromSource "tuple pattern as an Int argument" (rejectedWithFragment "TYPE MISMATCH" "The argument is a pattern that matches tuples of type:") "f : Int -> Int\nf ( a, b ) = a\n"
    , fromSource "second argument pattern" (rejectedWithFragment "TYPE MISMATCH" "The argument is a pattern that matches tuples of type:") "f : Int -> Int -> Int\nf a ( b, c ) = a\n"
    , fromSource "first case pattern" (rejectedWithFragment "TYPE MISMATCH" "Hint: Try using String.toInt to convert it to an integer?") "x =\n    case 1 of\n        \"a\" ->\n            1\n\n        _ ->\n            2\n"
    , fromSource "second case pattern" (rejectedWithFragment "TYPE MISMATCH" "Note: A `case` expression can only handle one type of value,") "x =\n    case \"s\" of\n        \"a\" ->\n            1\n\n        'c' ->\n            2\n\n        _ ->\n            3\n"
    , fromSource "constructor argument pattern" (rejectedWithFragment "TYPE MISMATCH" "Hint: Try using String.toInt to convert it to an integer?") "x =\n    case Just 1 of\n        Just \"a\" ->\n            1\n\n        _ ->\n            2\n"
    , fromSource "list entry pattern" (rejectedWithFragment "TYPE MISMATCH" "Hint: Want to convert a String into an Int? Use the String.t") "x =\n    case [ 1 ] of\n        [ 1, \"a\" ] ->\n            1\n\n        _ ->\n            2\n"
    , fromSource "tail pattern" (rejectedWithFragment "TYPE MISMATCH" "The pattern after (::) is trying to match strings:") "x =\n    case [ 1 ] of\n        a :: \"s\" ->\n            1\n\n        _ ->\n            2\n"
    , fromSource "lambda argument pattern" (rejectedWithFragment "TYPE MISMATCH" "Hint: Only Int and Float values work as numbers.") "x = (\\( a, b ) -> a) 1\n"
    , fromSource "record pattern" (rejectedWithFragment "TYPE MISMATCH" "The argument is a pattern that matches record values of type") "f : Int -> Int\nf { a } = a\n"
    , fromSource "unit pattern" (rejectedWithFragment "TYPE MISMATCH" "The argument is a pattern that matches unit values:") "f : Int -> Int\nf () = 1\n"
    , fromSource "list pattern" (rejectedWithFragment "TYPE MISMATCH" "Hint: Only Int and Float values work as numbers.") "x =\n    case 1 of\n        [] ->\n            1\n\n        _ ->\n            2\n"
    , fromSource "constructor pattern" (rejectedWithFragment "TYPE MISMATCH" "Hint: Only Int and Float values work as numbers.") "x =\n    case 1 of\n        Just a ->\n            1\n\n        _ ->\n            2\n"
    , fromSource "int pattern" (rejectedWithFragment "TYPE MISMATCH" "Hint: Want to convert an Int into a String? Use the String.f") "x =\n    case \"s\" of\n        1 ->\n            1\n\n        _ ->\n            2\n"
    , fromSource "char pattern" (rejectedWithFragment "TYPE MISMATCH" "Hint: Only Int and Float values work as numbers.") "x =\n    case 1 of\n        'c' ->\n            1\n\n        _ ->\n            2\n"
    , fromSource "bool pattern" (rejectedWithFragment "TYPE MISMATCH" "Hint: Only Int and Float values work as numbers.") "x =\n    case 1 of\n        True ->\n            1\n\n        _ ->\n            2\n"
    , fromSource "constructor pattern argument count" (rejectedWithFragment "TYPE MISMATCH" "The argument is a pattern that matches `T` values of type:") "type T = T Int\n\nf : T -> Int\nf (T a) = a\n\ng : Int -> Int\ng (T a) = a\n"
    , fromSource "cons head pattern" (rejectedWithFragment "TYPE MISMATCH" "Hint: Try using String.toInt to convert it to an integer?") "x =\n    case [ 1 ] of\n        \"a\" :: rest ->\n            1\n\n        _ ->\n            2\n"
    , fromSource "tuple component pattern" (rejectedWithFragment "TYPE MISMATCH" "Hint: Try using String.toInt to convert it to an integer?") "x =\n    case ( 1, 2 ) of\n        ( \"a\", b ) ->\n            1\n\n        _ ->\n            2\n"
    , fromSource "argument of a fixed constructor pattern" (rejectedWithFragment "TYPE MISMATCH" "Hint: Want to convert a String into an Int? Use the String.t") "type T = T Int\n\nx =\n    case T 1 of\n        T \"a\" ->\n            1\n\n        _ ->\n            2\n"
    , fromSource "string pattern" (rejectedWithFragment "TYPE MISMATCH" "Hint: Try using String.toInt to convert it to an integer?") "x =\n    case 1 of\n        \"s\" ->\n            1\n\n        _ ->\n            2\n"
    , fromSource "cons head against a list tail" (rejectedWithFragment "TYPE MISMATCH" "pattern") "x =\n    case [ 1 ] of\n        1 :: [ \"s\" ] ->\n            1\n\n        _ ->\n            2\n"
    , fromSource "cons head against a cons tail" (rejectedWithFragment "TYPE MISMATCH" "pattern") "x =\n    case [ 1 ] of\n        1 :: \"s\" :: rest ->\n            1\n\n        _ ->\n            2\n"
    ]



-- ============================================================================
-- INFINITE TYPES
-- ============================================================================


{-| Programs whose types would have to contain themselves.
-}
infiniteCases : List RejectedCase
infiniteCases =
    [ fromSource "self application" (rejectedWithFragment "INFINITE TYPE" "I am inferring a weird self-referential type for x:") "f x = x x\n"
    , fromSource "function returning itself" (rejectedWithFragment "INFINITE TYPE" "I am inferring a weird self-referential type for g:") "x =\n    let\n        g y = g\n    in\n    g\n"
    , fromSource "list of itself" (rejectedWithFragment "INFINITE TYPE" "I am inferring a weird self-referential type for x:") "f x = [ x, [ x ] ]\n"
    ]



-- ============================================================================
-- PRINTING
-- ============================================================================


{-| Mismatches that print types under imports with an alias or an exposing
list, local types that share a name with an imported one, and function and
type-application arguments that need parentheses.
-}
printingCases : List RejectedCase
printingCases =
    [ fromSource "type under an import alias"
        (rejectedWithFragment "TYPE MISMATCH" "This `Just` call produces:")
        "module Test exposing (..)\n\nimport Maybe as M\n\nx : Int\nx = M.Just 1\n"
    , fromSource "type under an exposing list"
        (rejectedWithFragment "TYPE MISMATCH" "This `Just` call produces:")
        "module Test exposing (..)\n\nimport Maybe exposing (Maybe)\nimport Tuple exposing (first, pair)\nimport List exposing (map)\n\nx : Int\nx = Just 1\n"
    , fromSource "local type named like an imported one"
        (rejectedWithFragment "TYPE MISMATCH" "This `identity` call produces:")
        "type Maybe a = Maybe a\n\nx : Maybe Int\nx = Basics.identity (Basics.always (Maybe.Just 1) 0)\n"
    , fromSource "function argument printed in parentheses"
        (rejectedWithFragment "TYPE MISMATCH" "This `g` value is a:")
        "g : (Int -> Int) -> Int\ng h = h 1\n\nx : Int\nx = g\n"
    , fromSource "type argument printed in parentheses"
        (rejectedWithFragment "TYPE MISMATCH" "The body is a list of type:")
        "x : Maybe (Maybe Int)\nx = [ Just (Just 1) ]\n"
    , fromSource "function in a type argument"
        (rejectedWithFragment "TYPE MISMATCH" "The body is a list of type:")
        "x : Maybe (Int -> Int)\nx = [ Just not ]\n"
    , fromSource "list type"
        (rejectedWithFragment "TYPE MISMATCH" "Hint: Only Int and Float values work as numbers.")
        "x : List (List Int)\nx = 1\n"
    , fromSource "type of a module that is not imported" (rejectedWithFragment "TYPE MISMATCH" "This `text` call produces:") "module Test exposing (..)\n\nimport Html\n\nx : Int\nx = Html.text \"a\"\n"
    , fromSource "empty record printed" (rejectedWithFragment "TYPE MISMATCH" "This `r` value is a:") "r = {}\n\nx : Int\nx = r\n"
    ]



-- ============================================================================
-- UNANNOTATED RECURSIVE GROUPS
-- ============================================================================


{-| Ill-typed groups of unannotated, mutually recursive top-level functions
(finding B3 of plans/sourceir-catalogue-test-logic.md). The members of such a
group must share their type variables until the group is solved; when an
earlier member's variables were generalized inside a later member, a use of
the earlier member there got a fresh instance, and both programs were accepted,
as stock Elm 0.19.1 accepts them.

  - "argument used at two types": `g` uses its argument as a `Bool` and calls
    `f 4`, and `f` passes its argument to `g`, so the argument must be both a
    `Bool` and a number. It was accepted with `f : number -> String`; the
    compiled program then tested the number `4` as a condition.
  - "result used at two types": `g` returns a `Maybe` and, through `f False`,
    uses that result as a `String`. It was accepted, and stock Elm's output
    crashes at run time (`str.toUpperCase is not a function` in the original
    report, which used `String.toUpper`; the mock interfaces have no
    `String.toUpper`, so this uses `++`).

-}
recursiveGroupCases : List RejectedCase
recursiveGroupCases =
    [ fromSource "argument used at two types"
        (rejectedWith "TYPE MISMATCH")
        """
f x =
    g x


g y =
    if y then
        "y was True"

    else
        f 4


testValue =
    f 0
"""
    , fromSource "result used at two types"
        (rejectedWith "TYPE MISMATCH")
        """
f b =
    g b


g b =
    if b then
        let
            n =
                f False
        in
        Just (n ++ "!")

    else
        Nothing


testValue =
    case f True of
        Just s ->
            s

        Nothing ->
            ""
"""
    ]
