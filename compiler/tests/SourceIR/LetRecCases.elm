module SourceIR.LetRecCases exposing (expectSuite)

{-| Programs in which a `let`-bound function calls itself or another function
of the same `let`, for pipeline-stage tests to run their checks over.

Elm has no keyword for a recursive `let`. `Compiler.Canonicalize.Expression`
works out which definitions of a `let` refer to one another and turns each
such group, including a single definition that refers only to itself, into a
`LetRec` node of `Compiler.AST.Canonical`; every other definition becomes an
ordinary `Let`, or a `LetDestruct` for a destructuring. These programs give a
stage under test `LetRec` groups of one and of two functions, a recursive
group inside a non-recursive function, and recursive functions that match
tuple, cons and `as` patterns.

The module asserts nothing itself. `expectSuite` is given the check, a
function from a `Src.Module` to an `Expectation`, and applies it to the
programs below in turn, stopping at the first that fails, so what is checked
depends on the caller.

Every program is a module named `Test` that imports `Basics` and `List` and
whose one top-level value, `testValue`, is a `let` expression. Each recursive
definition takes at least one argument and has no type annotation. The two
programs that match a list with `case` recurse down to the empty list. In each
of the others, the first recursive function called returns from the `then`
branch of an `if True`, so evaluating `testValue` would not recurse.

The programs, by group:

  - Self-recursive: a one-argument function; a function that recurses on the
    tail of a list through `case`; a two-argument function that calls itself
    with its arguments swapped; a function that calls itself with a new list
    as its accumulator.
  - Mutually recursive: `isEven` and `isOdd` in one `let`; and a function
    whose body is a `let` of two functions that call each other, while the
    outer function itself is not recursive.
  - Recursive with patterns: a tuple pattern as the argument, a list matched
    with a cons pattern in `case`, and an `as` pattern as the argument.
  - Two functions in one `let`, each calling only itself, used together in
    a tuple.

Among what is not tested: a group of three or more functions, a recursive
definition with a type annotation, a recursive function that uses a variable
of an enclosing function, a `let` that also destructures a pattern, and a
recursive definition with no arguments, which the canonicalizer rejects.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( boolExpr
        , callExpr
        , caseExpr
        , define
        , ifExpr
        , intExpr
        , letExpr
        , listExpr
        , makeModule
        , pAlias
        , pCons
        , pList
        , pTuple
        , pVar
        , tupleExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Returns one test, named `"Let rec expressions "` followed by `condStr`, that
applies `expectFn` to each program in turn and fails with the label of the
first case whose expectation fails, as `Compiler.BulkCheck.bulkCheck` reports
it.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Let rec expressions " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case of the module, group by group, each applying `expectFn`
to its program.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    selfRecursiveCases expectFn
        ++ mutuallyRecursiveCases expectFn
        ++ recursivePatternCases expectFn
        ++ complexRecursiveCases expectFn



-- ============================================================================
-- SELF-RECURSIVE FUNCTIONS
-- ============================================================================


{-| Returns the cases whose `let` holds one function that calls itself.
-}
selfRecursiveCases : (Src.Module -> Expectation) -> List TestCase
selfRecursiveCases expectFn =
    [ { label = "Simple recursive function", run = simpleRecursiveFn expectFn }
    , { label = "Recursive function with case", run = recursiveFnWithCase expectFn }
    , { label = "Recursive function with multiple args", run = recursiveFnMultipleArgs expectFn }
    , { label = "Recursive function with list accumulator", run = recursiveFnListAccumulator expectFn }
    ]


{-| Applies `expectFn` to the program whose value is
`let f n = if True then 1 else f 0 in f 5`.
-}
simpleRecursiveFn : (Src.Module -> Expectation) -> (() -> Expectation)
simpleRecursiveFn expectFn _ =
    let
        fn =
            define "f"
                [ pVar "n" ]
                (ifExpr
                    (boolExpr True)
                    (intExpr 1)
                    (callExpr (varExpr "f") [ intExpr 0 ])
                )

        modul =
            makeModule "testValue" (letExpr [ fn ] (callExpr (varExpr "f") [ intExpr 5 ]))
    in
    expectFn modul


{-| Applies `expectFn` to the program whose value is `len [ 1, 2 ]`, where
`len` returns `0` for `[]` and `len t` for `h :: t`. It recurses to the end of
the list and returns `0`.
-}
recursiveFnWithCase : (Src.Module -> Expectation) -> (() -> Expectation)
recursiveFnWithCase expectFn _ =
    let
        fn =
            define "len"
                [ pVar "list" ]
                (caseExpr (varExpr "list")
                    [ ( pList [], intExpr 0 )
                    , ( pCons (pVar "h") (pVar "t"), callExpr (varExpr "len") [ varExpr "t" ] )
                    ]
                )

        modul =
            makeModule "testValue" (letExpr [ fn ] (callExpr (varExpr "len") [ listExpr [ intExpr 1, intExpr 2 ] ]))
    in
    expectFn modul


{-| Applies `expectFn` to the program whose value is
`let f a b = if True then b else f b a in f 1 2`.
-}
recursiveFnMultipleArgs : (Src.Module -> Expectation) -> (() -> Expectation)
recursiveFnMultipleArgs expectFn _ =
    let
        fn =
            define "f"
                [ pVar "a", pVar "b" ]
                (ifExpr
                    (boolExpr True)
                    (varExpr "b")
                    (callExpr (varExpr "f") [ varExpr "b", varExpr "a" ])
                )

        modul =
            makeModule "testValue" (letExpr [ fn ] (callExpr (varExpr "f") [ intExpr 1, intExpr 2 ]))
    in
    expectFn modul


{-| Applies `expectFn` to the program whose value is
`let collect n acc = if True then acc else collect 0 [ n ] in collect 5 []`.
-}
recursiveFnListAccumulator : (Src.Module -> Expectation) -> (() -> Expectation)
recursiveFnListAccumulator expectFn _ =
    let
        fn =
            define "collect"
                [ pVar "n", pVar "acc" ]
                (ifExpr
                    (boolExpr True)
                    (varExpr "acc")
                    (callExpr (varExpr "collect") [ intExpr 0, listExpr [ varExpr "n" ] ])
                )

        modul =
            makeModule "testValue" (letExpr [ fn ] (callExpr (varExpr "collect") [ intExpr 5, listExpr [] ]))
    in
    expectFn modul



-- ============================================================================
-- MUTUALLY RECURSIVE FUNCTIONS
-- ============================================================================


{-| Returns the cases whose program contains a `let` of functions that call
each other.
-}
mutuallyRecursiveCases : (Src.Module -> Expectation) -> List TestCase
mutuallyRecursiveCases expectFn =
    [ { label = "Two mutually recursive functions", run = twoMutuallyRecursiveFns expectFn }
    , { label = "Nested mutually recursive", run = nestedMutuallyRecursive expectFn }
    ]


{-| Applies `expectFn` to the program whose value is `isEven 4`, where `isEven`
and `isOdd`, defined in that order in one `let`, each take `n`, return `True`
and `False` respectively under `if True`, and otherwise call the other with
`0`.
-}
twoMutuallyRecursiveFns : (Src.Module -> Expectation) -> (() -> Expectation)
twoMutuallyRecursiveFns expectFn _ =
    let
        isEven =
            define "isEven"
                [ pVar "n" ]
                (ifExpr (boolExpr True)
                    (boolExpr True)
                    (callExpr (varExpr "isOdd") [ intExpr 0 ])
                )

        isOdd =
            define "isOdd"
                [ pVar "n" ]
                (ifExpr (boolExpr True)
                    (boolExpr False)
                    (callExpr (varExpr "isEven") [ intExpr 0 ])
                )

        modul =
            makeModule "testValue" (letExpr [ isEven, isOdd ] (callExpr (varExpr "isEven") [ intExpr 4 ]))
    in
    expectFn modul


{-| Applies `expectFn` to the program whose value is `outer 5`, where the body
of `outer n` is a `let` of `inner1 x = if True then 0 else inner2 x` and
`inner2 x = inner1 x`, returning `inner1 n`.

Only the inner `let` is recursive: `outer` does not call itself.

-}
nestedMutuallyRecursive : (Src.Module -> Expectation) -> (() -> Expectation)
nestedMutuallyRecursive expectFn _ =
    let
        outer =
            define "outer"
                [ pVar "n" ]
                (letExpr
                    [ define "inner1"
                        [ pVar "x" ]
                        (ifExpr (boolExpr True) (intExpr 0) (callExpr (varExpr "inner2") [ varExpr "x" ]))
                    , define "inner2"
                        [ pVar "x" ]
                        (callExpr (varExpr "inner1") [ varExpr "x" ])
                    ]
                    (callExpr (varExpr "inner1") [ varExpr "n" ])
                )

        modul =
            makeModule "testValue" (letExpr [ outer ] (callExpr (varExpr "outer") [ intExpr 5 ]))
    in
    expectFn modul



-- ============================================================================
-- RECURSIVE WITH PATTERNS
-- ============================================================================


{-| Returns the cases whose recursive function matches a tuple, cons or `as`
pattern.
-}
recursivePatternCases : (Src.Module -> Expectation) -> List TestCase
recursivePatternCases expectFn =
    [ { label = "Recursive with tuple pattern", run = recursiveWithTuplePattern expectFn }
    , { label = "Recursive with cons pattern", run = recursiveWithConsPattern expectFn }
    , { label = "Recursive with alias pattern", run = recursiveWithAliasPattern expectFn }
    ]


{-| Applies `expectFn` to the program whose value is
`let process ( a, b ) = if True then 0 else process ( b, a ) in process ( 1, 2 )`.
-}
recursiveWithTuplePattern : (Src.Module -> Expectation) -> (() -> Expectation)
recursiveWithTuplePattern expectFn _ =
    let
        fn =
            define "process"
                [ pTuple (pVar "a") (pVar "b") ]
                (ifExpr (boolExpr True)
                    (intExpr 0)
                    (callExpr (varExpr "process") [ tupleExpr (varExpr "b") (varExpr "a") ])
                )

        modul =
            makeModule "testValue" (letExpr [ fn ] (callExpr (varExpr "process") [ tupleExpr (intExpr 1) (intExpr 2) ]))
    in
    expectFn modul


{-| Applies `expectFn` to the program whose value is `sum [ 1, 2, 3 ]`, where
`sum` returns `0` for `[]` and `sum t` for `h :: t`. It has the same shape as
the program of `recursiveFnWithCase`, with a longer list, and also returns
`0`.
-}
recursiveWithConsPattern : (Src.Module -> Expectation) -> (() -> Expectation)
recursiveWithConsPattern expectFn _ =
    let
        fn =
            define "sum"
                [ pVar "list" ]
                (caseExpr (varExpr "list")
                    [ ( pList [], intExpr 0 )
                    , ( pCons (pVar "h") (pVar "t"), callExpr (varExpr "sum") [ varExpr "t" ] )
                    ]
                )

        modul =
            makeModule "testValue" (letExpr [ fn ] (callExpr (varExpr "sum") [ listExpr [ intExpr 1, intExpr 2, intExpr 3 ] ]))
    in
    expectFn modul


{-| Applies `expectFn` to the program whose value is `process 5`, where
`process (x as whole)` returns `( x, whole )` under `if True` and otherwise
calls `process x`. Both names bind the whole argument.
-}
recursiveWithAliasPattern : (Src.Module -> Expectation) -> (() -> Expectation)
recursiveWithAliasPattern expectFn _ =
    let
        fn =
            define "process"
                [ pAlias (pVar "x") "whole" ]
                (ifExpr (boolExpr True)
                    (tupleExpr (varExpr "x") (varExpr "whole"))
                    (callExpr (varExpr "process") [ varExpr "x" ])
                )

        modul =
            makeModule "testValue" (letExpr [ fn ] (callExpr (varExpr "process") [ intExpr 5 ]))
    in
    expectFn modul



-- ============================================================================
-- COMPLEX RECURSIVE
-- ============================================================================


{-| Returns the case whose `let` holds two recursive functions that do not call
each other.
-}
complexRecursiveCases : (Src.Module -> Expectation) -> List TestCase
complexRecursiveCases expectFn =
    [ { label = "Two recursive functions with fixed values", run = twoRecursiveFnsFixed expectFn }
    ]


{-| Applies `expectFn` to the program whose value is `( f 1, g 2 )`, where
`f n = if True then 1 else f 0` and `g n = if True then 2 else g 0` are
defined in one `let`. Each calls only itself.
-}
twoRecursiveFnsFixed : (Src.Module -> Expectation) -> (() -> Expectation)
twoRecursiveFnsFixed expectFn _ =
    let
        f =
            define "f"
                [ pVar "n" ]
                (ifExpr (boolExpr True)
                    (intExpr 1)
                    (callExpr (varExpr "f") [ intExpr 0 ])
                )

        g =
            define "g"
                [ pVar "n" ]
                (ifExpr (boolExpr True)
                    (intExpr 2)
                    (callExpr (varExpr "g") [ intExpr 0 ])
                )

        modul =
            makeModule "testValue"
                (letExpr [ f, g ]
                    (tupleExpr
                        (callExpr (varExpr "f") [ intExpr 1 ])
                        (callExpr (varExpr "g") [ intExpr 2 ])
                    )
                )
    in
    expectFn modul
