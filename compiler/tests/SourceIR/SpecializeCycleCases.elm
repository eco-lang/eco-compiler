module SourceIR.SpecializeCycleCases exposing (expectSuite, suite)

{-| Programs with recursive definitions, so that a stage of the compiler that
mishandles recursion, by failing or crashing on it, makes a test fail.

A _recursion group_ is a set of definitions that call one another in a cycle;
a single function that calls itself is a group of one. The cases cover groups
of one, two and three functions, functions of different arities in one group,
values that use a recursive function without being part of its group, and
_benign polymorphic cycles_: recursion groups in which a type variable is
never fixed to a concrete type and no value of that type is ever present,
either because the list involved is always empty or because the type is a
phantom type whose constructor carries nothing.

Each case builds one `Src.Module` with `Compiler.AST.SourceBuilder`. All but
the last use `makeModule`, which makes a module with one unannotated top-level
value, `testValue`; their recursive functions are `let`-bound inside it, so in
those cases the recursion is between local definitions, not top-level ones.
Only the phantom-type case declares its mutually recursive functions at top
level, with annotations. Each case's docstring shows its program as Elm source;
the built tree has no `Parens` node where the source has parentheses. The
integer literals are unannotated, so their type is `number` unless something
fixes it.

The cases only build programs; what is checked is decided by the expectation
function they are given. `expectSuite` runs all nine against one expectation,
inside one test that stops at the first failing case (see
`Compiler.BulkCheck`). `suite` runs them against
`TestLogic.TestPipeline.expectMonomorphization`, which passes when the
program compiles through monomorphization with the substitution engine and the
resulting graph has a `main` and at least one node. The cases are:

  - two local functions that call each other (`isEven` and `isOdd`);
  - three local functions that call one another in a ring;
  - two mutually recursive local functions, of one argument and of two;
  - a self-recursive local `factorial` and a local value that calls it;
  - a self-recursive local `countdown` and two local values that call it,
    one of them unused;
  - two mutually recursive local functions over lists that fix neither the
    list's element type nor their result's, applied to a list of integer
    literals;
  - a non-recursive local function holding a self-recursive local function;
  - a self-recursive local list function applied only to `[]`;
  - two mutually recursive top-level functions over a phantom type.

Among what `suite` does not test: which specializations monomorphization
produces for a recursion group, or that each function in one becomes a callable
node; no program is evaluated.

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
        , ctorExpr
        , define
        , ifExpr
        , intExpr
        , letExpr
        , listExpr
        , makeModule
        , makeModuleWithTypedDefsUnionsAliases
        , pAnything
        , pCons
        , pList
        , pVar
        , qualVarExpr
        , tLambda
        , tType
        , tVar
        , tupleExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)
import TestLogic.TestPipeline exposing (expectMonomorphization)


{-| A test that runs the cases in order against `expectMonomorphization`,
stopping at the first that fails. A case passes when its program compiles
through monomorphization with the substitution engine and the resulting graph
has a `main` and at least one node.
-}
suite : Test
suite =
    Test.describe "Specialize.elm cycle coverage"
        [ expectSuite expectMonomorphization "monomorphizes cycles"
        ]


{-| Builds one test, named `"Specialize cycles "` followed by `condStr`, that
checks the cases in order with `expectFn`, stops at the first that fails, and
reports that case's label.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Specialize cycles " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns all nine cases, each checked with `expectFn`, group by group in the
order of this file.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.concat
        [ mutualRecursionCases expectFn
        , cycleWithValuesCases expectFn
        , multiNodeCycleCases expectFn
        , benignCycleCases expectFn
        ]



-- ============================================================================
-- MUTUAL RECURSION TESTS
-- ============================================================================


{-| Returns the three cases whose local functions call one another, each
checked with `expectFn`.
-}
mutualRecursionCases : (Src.Module -> Expectation) -> List TestCase
mutualRecursionCases expectFn =
    [ { label = "Two mutually recursive functions (isEven/isOdd)", run = twoMutuallyRecursiveFns expectFn }
    , { label = "Three mutually recursive functions", run = threeMutuallyRecursiveFns expectFn }
    , { label = "Mutually recursive with different arities", run = mutuallyRecursiveDifferentArities expectFn }
    ]


{-| Applies `expectFn` to a program in which two local functions call each
other:

    testValue =
        let
            isEven n =
                if n == 0 then
                    True

                else
                    isOdd (n - 1)

            isOdd n =
                if n == 0 then
                    False

                else
                    isEven (n - 1)
        in
        isEven 10

-}
twoMutuallyRecursiveFns : (Src.Module -> Expectation) -> (() -> Expectation)
twoMutuallyRecursiveFns expectFn _ =
    let
        isEven =
            define "isEven"
                [ pVar "n" ]
                (ifExpr
                    (binopsExpr [ ( varExpr "n", "==" ) ] (intExpr 0))
                    (boolExpr True)
                    (callExpr (varExpr "isOdd")
                        [ binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1) ]
                    )
                )

        isOdd =
            define "isOdd"
                [ pVar "n" ]
                (ifExpr
                    (binopsExpr [ ( varExpr "n", "==" ) ] (intExpr 0))
                    (boolExpr False)
                    (callExpr (varExpr "isEven")
                        [ binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1) ]
                    )
                )

        modul =
            makeModule "testValue"
                (letExpr [ isEven, isOdd ]
                    (callExpr (varExpr "isEven") [ intExpr 10 ])
                )
    in
    expectFn modul


{-| Applies `expectFn` to a program in which three local functions call one
another in a ring, `funcA` calling `funcB`, `funcB` calling `funcC` and
`funcC` calling `funcA`:

    testValue =
        let
            funcA n =
                if n <= 0 then
                    0

                else
                    funcB (n - 1)

            funcB n =
                if n <= 0 then
                    1

                else
                    funcC (n - 1)

            funcC n =
                if n <= 0 then
                    2

                else
                    funcA (n - 1)
        in
        funcA 10

-}
threeMutuallyRecursiveFns : (Src.Module -> Expectation) -> (() -> Expectation)
threeMutuallyRecursiveFns expectFn _ =
    let
        funcA =
            define "funcA"
                [ pVar "n" ]
                (ifExpr
                    (binopsExpr [ ( varExpr "n", "<=" ) ] (intExpr 0))
                    (intExpr 0)
                    (callExpr (varExpr "funcB")
                        [ binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1) ]
                    )
                )

        funcB =
            define "funcB"
                [ pVar "n" ]
                (ifExpr
                    (binopsExpr [ ( varExpr "n", "<=" ) ] (intExpr 0))
                    (intExpr 1)
                    (callExpr (varExpr "funcC")
                        [ binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1) ]
                    )
                )

        funcC =
            define "funcC"
                [ pVar "n" ]
                (ifExpr
                    (binopsExpr [ ( varExpr "n", "<=" ) ] (intExpr 0))
                    (intExpr 2)
                    (callExpr (varExpr "funcA")
                        [ binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1) ]
                    )
                )

        modul =
            makeModule "testValue"
                (letExpr [ funcA, funcB, funcC ]
                    (callExpr (varExpr "funcA") [ intExpr 10 ])
                )
    in
    expectFn modul


{-| Applies `expectFn` to a program in which a local function of one argument
and a local function of two call each other:

    testValue =
        let
            singleArg n =
                if n <= 0 then
                    0

                else
                    doubleArg n 1

            doubleArg a b =
                if a <= 0 then
                    b

                else
                    singleArg (a - b)
        in
        singleArg 5

-}
mutuallyRecursiveDifferentArities : (Src.Module -> Expectation) -> (() -> Expectation)
mutuallyRecursiveDifferentArities expectFn _ =
    let
        singleArg =
            define "singleArg"
                [ pVar "n" ]
                (ifExpr
                    (binopsExpr [ ( varExpr "n", "<=" ) ] (intExpr 0))
                    (intExpr 0)
                    (callExpr (varExpr "doubleArg")
                        [ varExpr "n", intExpr 1 ]
                    )
                )

        doubleArg =
            define "doubleArg"
                [ pVar "a", pVar "b" ]
                (ifExpr
                    (binopsExpr [ ( varExpr "a", "<=" ) ] (intExpr 0))
                    (varExpr "b")
                    (callExpr (varExpr "singleArg")
                        [ binopsExpr [ ( varExpr "a", "-" ) ] (varExpr "b") ]
                    )
                )

        modul =
            makeModule "testValue"
                (letExpr [ singleArg, doubleArg ]
                    (callExpr (varExpr "singleArg") [ intExpr 5 ])
                )
    in
    expectFn modul



-- ============================================================================
-- VALUES THAT USE A RECURSIVE FUNCTION
-- ============================================================================


{-| Returns the two cases in which local values call a self-recursive local
function, each checked with `expectFn`. In neither is a value part of the
recursion.
-}
cycleWithValuesCases : (Src.Module -> Expectation) -> List TestCase
cycleWithValuesCases expectFn =
    [ { label = "Value depending on recursive function", run = valueWithRecursiveFunction expectFn }
    , { label = "Multiple values using a recursive function", run = multipleValuesWithRecursion expectFn }
    ]


{-| Applies `expectFn` to a program with a self-recursive local function and a
local value that calls it:

    testValue =
        let
            factorial n =
                if n <= 1 then
                    1

                else
                    n * factorial (n - 1)

            result =
                factorial 5
        in
        result

-}
valueWithRecursiveFunction : (Src.Module -> Expectation) -> (() -> Expectation)
valueWithRecursiveFunction expectFn _ =
    let
        factorial =
            define "factorial"
                [ pVar "n" ]
                (ifExpr
                    (binopsExpr [ ( varExpr "n", "<=" ) ] (intExpr 1))
                    (intExpr 1)
                    (binopsExpr
                        [ ( varExpr "n", "*" ) ]
                        (callExpr (varExpr "factorial")
                            [ binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1) ]
                        )
                    )
                )

        result =
            define "result" [] (callExpr (varExpr "factorial") [ intExpr 5 ])

        modul =
            makeModule "testValue"
                (letExpr [ factorial, result ]
                    (varExpr "result")
                )
    in
    expectFn modul


{-| Applies `expectFn` to a program with a self-recursive local function and
two local values that call it, both used in the result:

    testValue =
        let
            countdown n =
                if n <= 0 then
                    []

                else
                    n :: countdown (n - 1)

            numbers =
                countdown 5

            shorter =
                countdown 3
        in
        ( numbers, shorter )

-}
multipleValuesWithRecursion : (Src.Module -> Expectation) -> (() -> Expectation)
multipleValuesWithRecursion expectFn _ =
    let
        countdown =
            define "countdown"
                [ pVar "n" ]
                (ifExpr
                    (binopsExpr [ ( varExpr "n", "<=" ) ] (intExpr 0))
                    (listExpr [])
                    (binopsExpr
                        [ ( varExpr "n", "::" ) ]
                        (callExpr (varExpr "countdown")
                            [ binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1) ]
                        )
                    )
                )

        numbers =
            define "numbers" [] (callExpr (varExpr "countdown") [ intExpr 5 ])

        shorter =
            define "shorter" [] (callExpr (varExpr "countdown") [ intExpr 3 ])

        modul =
            makeModule "testValue"
                (letExpr [ countdown, numbers, shorter ]
                    (tupleExpr (varExpr "numbers") (varExpr "shorter"))
                )
    in
    expectFn modul



-- ============================================================================
-- POLYMORPHIC AND NESTED RECURSION
-- ============================================================================


{-| Returns two cases, each checked with `expectFn`: two mutually recursive
local functions whose types are left polymorphic, and a self-recursive local
function nested inside another local function.
-}
multiNodeCycleCases : (Src.Module -> Expectation) -> List TestCase
multiNodeCycleCases expectFn =
    [ { label = "Cycle with polymorphic functions", run = cycleWithPolymorphicFunctions expectFn }
    , { label = "Nested cycles", run = nestedCycles expectFn }
    ]


{-| Applies `expectFn` to a program in which two local functions over lists
call each other:

    testValue =
        let
            process xs =
                case xs of
                    [] ->
                        []

                    nonEmpty ->
                        transform nonEmpty

            transform xs =
                process (List.drop 1 xs)
        in
        process [ 1, 2 ]

Nothing in the two functions fixes the element type of the list they take or
of the list they return, so both are polymorphic; `testValue` applies
`process` to a list of integer literals. Each round drops one element, so the
recursion ends.

-}
cycleWithPolymorphicFunctions : (Src.Module -> Expectation) -> (() -> Expectation)
cycleWithPolymorphicFunctions expectFn _ =
    let
        processF =
            define "process"
                [ pVar "xs" ]
                (caseExpr (varExpr "xs")
                    [ ( pList [], listExpr [] )
                    , ( pVar "nonEmpty", callExpr (varExpr "transform") [ varExpr "nonEmpty" ] )
                    ]
                )

        transformF =
            define "transform"
                [ pVar "xs" ]
                (callExpr (varExpr "process")
                    [ callExpr (qualVarExpr "List" "drop") [ intExpr 1, varExpr "xs" ] ]
                )

        modul =
            makeModule "testValue"
                (letExpr [ processF, transformF ]
                    (callExpr (varExpr "process") [ listExpr [ intExpr 1, intExpr 2 ] ])
                )
    in
    expectFn modul


{-| Applies `expectFn` to a program in which a self-recursive local function
is defined inside another local function, which is not itself recursive:

    testValue =
        let
            outer n =
                let
                    inner m =
                        if m <= 0 then
                            0

                        else
                            inner (m - 1)
                in
                inner n
        in
        outer 5

-}
nestedCycles : (Src.Module -> Expectation) -> (() -> Expectation)
nestedCycles expectFn _ =
    let
        outerFn =
            define "outer"
                [ pVar "n" ]
                (letExpr
                    [ define "inner"
                        [ pVar "m" ]
                        (ifExpr
                            (binopsExpr [ ( varExpr "m", "<=" ) ] (intExpr 0))
                            (intExpr 0)
                            (callExpr (varExpr "inner")
                                [ binopsExpr [ ( varExpr "m", "-" ) ] (intExpr 1) ]
                            )
                        )
                    ]
                    (callExpr (varExpr "inner") [ varExpr "n" ])
                )

        modul =
            makeModule "testValue"
                (letExpr [ outerFn ]
                    (callExpr (varExpr "outer") [ intExpr 5 ])
                )
    in
    expectFn modul



-- ============================================================================
-- BENIGN CYCLE TESTS
-- ============================================================================


{-| Returns the two benign polymorphic cycle cases, each checked with
`expectFn`.
-}
benignCycleCases : (Src.Module -> Expectation) -> List TestCase
benignCycleCases expectFn =
    [ { label = "Recursive list function with unconstrained element type", run = recursiveListUnconstrained expectFn }
    , { label = "Mutually recursive functions over phantom custom type", run = mutualRecursionPhantomType expectFn }
    ]


{-| Applies `expectFn` to a program in which a self-recursive local function
over lists is applied only to the empty list:

    testValue =
        let
            process xs =
                case xs of
                    [] ->
                        []

                    _ :: rest ->
                        process rest
        in
        process []

Nothing in the program fixes the element type of either list, and no element
ever exists, so this is a benign polymorphic cycle.

-}
recursiveListUnconstrained : (Src.Module -> Expectation) -> (() -> Expectation)
recursiveListUnconstrained expectFn _ =
    let
        processF =
            define "process"
                [ pVar "xs" ]
                (caseExpr (varExpr "xs")
                    [ ( pList [], listExpr [] )
                    , ( pCons pAnything (pVar "rest")
                      , callExpr (varExpr "process") [ varExpr "rest" ]
                      )
                    ]
                )

        modul =
            makeModule "testValue"
                (letExpr [ processF ]
                    (callExpr (varExpr "process") [ listExpr [] ])
                )
    in
    expectFn modul


{-| Applies `expectFn` to a program in which two annotated top-level functions
over a phantom type call each other:

    type Box a
        = Box

    f : Box a -> Box a
    f x =
        g x

    g : Box a -> Box a
    g x =
        f x

    testValue : Box a
    testValue =
        f Box

`Box a` is a phantom type: its constructor carries nothing, so a `Box a`
holds no value of `a`, and nothing in the program fixes `a`. This makes `f` and
`g` a benign polymorphic cycle. Unlike the other cases, the module is built with
`makeModuleWithTypedDefsUnionsAliases`, which imports the standard set; the
module is named `Test`, as in the other cases.

-}
mutualRecursionPhantomType : (Src.Module -> Expectation) -> (() -> Expectation)
mutualRecursionPhantomType expectFn _ =
    let
        boxType =
            tType "Box" [ tVar "a" ]

        boxUnion : UnionDef
        boxUnion =
            { name = "Box"
            , args = [ "a" ]
            , ctors = [ { name = "Box", args = [] } ]
            }

        fDef : TypedDef
        fDef =
            { name = "f"
            , args = [ pVar "x" ]
            , tipe = tLambda boxType boxType
            , body = callExpr (varExpr "g") [ varExpr "x" ]
            }

        gDef : TypedDef
        gDef =
            { name = "g"
            , args = [ pVar "x" ]
            , tipe = tLambda boxType boxType
            , body = callExpr (varExpr "f") [ varExpr "x" ]
            }

        mainDef : TypedDef
        mainDef =
            { name = "testValue"
            , args = []
            , tipe = boxType
            , body = callExpr (varExpr "f") [ ctorExpr "Box" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ fDef, gDef, mainDef ]
                [ boxUnion ]
                []
    in
    expectFn modul
