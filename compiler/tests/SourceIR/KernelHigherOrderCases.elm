module SourceIR.KernelHigherOrderCases exposing (expectSuite)

{-| Source programs, most of which hand a function to a list function, each
given to a check that the caller supplies.

A function passed as an argument is a value, not the target of a call where it
is written, and that value can be a reference to a kernel function, a named
function, a lambda or a partial application. A stage that mishandles one of
these kinds of function value could go unnoticed without a program that uses
it, so these cases build one or more programs for each kind.

Every case builds a module named `Test` whose one top-level value is
`testValue`, and asserts nothing itself: `expectSuite` runs the caller's
expectation on the modules in order, and `Compiler.BulkCheck.bulkCheck` stops at
the first that fails and reports only that one.

The first five cases call `Elm.Kernel.*` names directly, in a module built with
`makeKernelModule`. Such a name is a kernel reference only when the module
belongs to a kernel package (see `findVarQual` in
`Compiler.Canonicalize.Expression`); elsewhere it is not found. Every kernel
they name is one the C++ kernel exports (`elm-kernel-cpp/src/KernelExports.h`);
it has list kernels for `map2` and the sorts, but none for `map` or `foldl`.
The other fourteen call the `List` and `Basics` functions in a module built
with `makeModule`, which imports only `Basics` and `List`. `List.reverse`,
`List.length` and `++` take no function argument.

The programs, one per case, in the order they run:

  - `Elm.Kernel.List.map2 Elm.Kernel.Basics.sub [10, 20, 30] [1, 2, 3]`.
  - `Elm.Kernel.List.sortBy (\x -> 0 - x) [3, 1, 2]`.
  - `Elm.Kernel.List.sortBy Tuple.first [(2, "b"), (1, "a")]`.
  - `Elm.Kernel.List.map2` of a lambda that itself calls
    `Elm.Kernel.List.map2 (\x y -> x + y)`, over `[[1, 2], [3, 4]]` and
    `[[5, 6], [7, 8]]`.
  - `Elm.Kernel.List.sortWith Elm.Kernel.Utils.compare [3, 1, 2]`.
  - `List.map double [1, 2, 3]`, with `double x = x * 2` defined in a `let`.
  - `List.map (\x -> x * 2) [1, 2, 3]`.
  - `List.map addOne [1, 2, 3]`, with `add a b = a + b` and `addOne = add 1`
    defined in a `let`.
  - `List.filter isPositive [0, 1, 0, 2]`, with `isPositive x = x > 0`
    defined in a `let`.
  - `List.foldl (+) 0 [1, 2, 3, 4]`.
  - `List.foldr (++) "" ["a", "b", "c"]`.
  - `List.map Basics.not [True, False, True]`.
  - `List.reverse [1, 2, 3]`.
  - `List.length [1, 2, 3]`.
  - `[1, 2, 3] |> List.map double`.
  - `[1, 2] ++ [3, 4]`.
  - `List.map (curried 5) [1, 2, 3]`, with `curried x = \y -> x + y`.
  - `List.foldl (combine 2) 0 [1, 2, 3]`, with
    `combine factor x acc = (factor * x) + acc`.
  - `List.filter (eq 5) [1, 2, 5, 3, 5]`, with `eq a b = a == b`.

Among what is not tested: `(==)` partially applied directly, and the library
`List` functions over more than one list, such as `List.map2`.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder exposing (binopsExpr, boolExpr, callExpr, define, intExpr, lambdaExpr, letExpr, listExpr, makeKernelModule, makeModule, opExpr, pVar, qualVarExpr, strExpr, tupleExpr, varExpr)
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Kernel higher-order " followed by `condStr`, that
passes when `expectFn` passes on every case's module.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Kernel higher-order " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case in this module, each labelled and with `expectFn`
deferred until the case is run.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "List.map2 with kernel Basics.sub", run = map2WithKernelSub expectFn }
    , { label = "List.sortBy with lambda key", run = sortByLambda expectFn }
    , { label = "List.sortBy on tuples with Tuple.first", run = sortByOnTuples expectFn }
    , { label = "Nested List.map2", run = nestedMap2 expectFn }
    , { label = "List.sortWith with kernel compare", run = sortWithKernelCompare expectFn }
    , { label = "List.map with user-defined function", run = mapWithUserFunction expectFn }
    , { label = "List.map with anonymous lambda", run = mapWithAnonymousLambda expectFn }
    , { label = "List.map with partial application", run = mapWithPartialApplication expectFn }
    , { label = "List.filter with user predicate", run = filterWithUserPredicate expectFn }
    , { label = "List.foldl with operator as value", run = foldlWithOperatorValue expectFn }
    , { label = "List.foldr with string append operator", run = foldrWithStringAppend expectFn }
    , { label = "List.map with Bool result", run = mapWithBoolResult expectFn }
    , { label = "List.reverse (no function argument)", run = listReverse expectFn }
    , { label = "List.length (no function argument)", run = listLength expectFn }
    , { label = "Pipeline List.map", run = pipelineListMap expectFn }
    , { label = "List.concat via append", run = listConcatViaAppend expectFn }
    , { label = "List.map with partial app of multi-stage fn", run = mapWithPartialAppMultiStage expectFn }
    , { label = "List.foldl with partial app accumulator", run = foldlWithPartialAppAccum expectFn }
    , { label = "List.filter with partially applied equality", run = filterWithPartialEq expectFn }
    ]


{-| Returns a check of `expectFn` against
`Elm.Kernel.List.map2 Elm.Kernel.Basics.sub [10, 20, 30] [1, 2, 3]`, which
passes a kernel function by name to a kernel function.
-}
map2WithKernelSub : (Src.Module -> Expectation) -> (() -> Expectation)
map2WithKernelSub expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Elm.Kernel.List" "map2")
                [ qualVarExpr "Elm.Kernel.Basics" "sub"
                , listExpr [ intExpr 10, intExpr 20, intExpr 30 ]
                , listExpr [ intExpr 1, intExpr 2, intExpr 3 ]
                ]
            )
        )


{-| Returns a check of `expectFn` against
`Elm.Kernel.List.sortBy (\x -> 0 - x) [3, 1, 2]`.
-}
sortByLambda : (Src.Module -> Expectation) -> (() -> Expectation)
sortByLambda expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Elm.Kernel.List" "sortBy")
                [ lambdaExpr [ pVar "x" ] (binopsExpr [ ( intExpr 0, "-" ) ] (varExpr "x"))
                , listExpr [ intExpr 3, intExpr 1, intExpr 2 ]
                ]
            )
        )


{-| Returns a check of `expectFn` against
`Elm.Kernel.List.sortBy Tuple.first [(2, "b"), (1, "a")]`, which passes a
library function by name to a kernel function.
-}
sortByOnTuples : (Src.Module -> Expectation) -> (() -> Expectation)
sortByOnTuples expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Elm.Kernel.List" "sortBy")
                [ qualVarExpr "Tuple" "first"
                , listExpr [ tupleExpr (intExpr 2) (strExpr "b"), tupleExpr (intExpr 1) (strExpr "a") ]
                ]
            )
        )


{-| Returns a check of `expectFn` against an `Elm.Kernel.List.map2` call whose
function is a lambda over `xs` and `ys` making a second `Elm.Kernel.List.map2`
call with `\x y -> x + y`, `xs` and `ys`, over `[[1, 2], [3, 4]]` and
`[[5, 6], [7, 8]]`.
-}
nestedMap2 : (Src.Module -> Expectation) -> (() -> Expectation)
nestedMap2 expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Elm.Kernel.List" "map2")
                [ lambdaExpr [ pVar "xs", pVar "ys" ]
                    (callExpr (qualVarExpr "Elm.Kernel.List" "map2")
                        [ lambdaExpr [ pVar "x", pVar "y" ] (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "y"))
                        , varExpr "xs"
                        , varExpr "ys"
                        ]
                    )
                , listExpr [ listExpr [ intExpr 1, intExpr 2 ], listExpr [ intExpr 3, intExpr 4 ] ]
                , listExpr [ listExpr [ intExpr 5, intExpr 6 ], listExpr [ intExpr 7, intExpr 8 ] ]
                ]
            )
        )


{-| Returns a check of `expectFn` against
`Elm.Kernel.List.sortWith Elm.Kernel.Utils.compare [3, 1, 2]`, which passes a
two-argument kernel function by name to a kernel function.
-}
sortWithKernelCompare : (Src.Module -> Expectation) -> (() -> Expectation)
sortWithKernelCompare expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Elm.Kernel.List" "sortWith")
                [ qualVarExpr "Elm.Kernel.Utils" "compare"
                , listExpr [ intExpr 3, intExpr 1, intExpr 2 ]
                ]
            )
        )


{-| Returns a check of `expectFn` against `List.map double [1, 2, 3]`, where
`double x = x * 2` is defined in a `let` around the call and passed by name.
-}
mapWithUserFunction : (Src.Module -> Expectation) -> (() -> Expectation)
mapWithUserFunction expectFn _ =
    let
        double =
            define "double" [ pVar "x" ] (binopsExpr [ ( varExpr "x", "*" ) ] (intExpr 2))

        modul =
            makeModule "testValue"
                (letExpr [ double ]
                    (callExpr (qualVarExpr "List" "map")
                        [ varExpr "double"
                        , listExpr [ intExpr 1, intExpr 2, intExpr 3 ]
                        ]
                    )
                )
    in
    expectFn modul


{-| Returns a check of `expectFn` against `List.map (\x -> x * 2) [1, 2, 3]`.
-}
mapWithAnonymousLambda : (Src.Module -> Expectation) -> (() -> Expectation)
mapWithAnonymousLambda expectFn _ =
    let
        modul =
            makeModule "testValue"
                (callExpr (qualVarExpr "List" "map")
                    [ lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "*" ) ] (intExpr 2))
                    , listExpr [ intExpr 1, intExpr 2, intExpr 3 ]
                    ]
                )
    in
    expectFn modul


{-| Returns a check of `expectFn` against `List.map addOne [1, 2, 3]`, where a
`let` defines `add a b = a + b` and `addOne = add 1`.

The partial application is the body of the definition `addOne`, not an
argument written in the call.

-}
mapWithPartialApplication : (Src.Module -> Expectation) -> (() -> Expectation)
mapWithPartialApplication expectFn _ =
    let
        add =
            define "add" [ pVar "a", pVar "b" ] (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b"))

        addOne =
            define "addOne" [] (callExpr (varExpr "add") [ intExpr 1 ])

        modul =
            makeModule "testValue"
                (letExpr [ add, addOne ]
                    (callExpr (qualVarExpr "List" "map")
                        [ varExpr "addOne"
                        , listExpr [ intExpr 1, intExpr 2, intExpr 3 ]
                        ]
                    )
                )
    in
    expectFn modul


{-| Returns a check of `expectFn` against
`List.filter isPositive [1, 2, 3, 4, 5]`, where `isPositive x = x > 0` is
defined in a `let`. Every element passes the predicate.
-}
filterWithUserPredicate : (Src.Module -> Expectation) -> (() -> Expectation)
filterWithUserPredicate expectFn _ =
    let
        isPositive =
            define "isPositive"
                [ pVar "x" ]
                (binopsExpr [ ( varExpr "x", ">" ) ] (intExpr 0))

        modul =
            makeModule "testValue"
                (letExpr [ isPositive ]
                    (callExpr (qualVarExpr "List" "filter")
                        [ varExpr "isPositive"
                        , listExpr [ intExpr 0, intExpr 1, intExpr 0, intExpr 2 ]
                        ]
                    )
                )
    in
    expectFn modul


{-| Returns a check of `expectFn` against `List.foldl (+) 0 [1, 2, 3, 4]`, which
passes the operator `(+)` as a value.
-}
foldlWithOperatorValue : (Src.Module -> Expectation) -> (() -> Expectation)
foldlWithOperatorValue expectFn _ =
    let
        modul =
            makeModule "testValue"
                (callExpr (qualVarExpr "List" "foldl")
                    [ opExpr "+"
                    , intExpr 0
                    , listExpr [ intExpr 1, intExpr 2, intExpr 3, intExpr 4 ]
                    ]
                )
    in
    expectFn modul


{-| Returns a check of `expectFn` against `List.foldr (++) "" ["a", "b", "c"]`,
which passes the operator `(++)` as a value.
-}
foldrWithStringAppend : (Src.Module -> Expectation) -> (() -> Expectation)
foldrWithStringAppend expectFn _ =
    let
        modul =
            makeModule "testValue"
                (callExpr (qualVarExpr "List" "foldr")
                    [ opExpr "++"
                    , strExpr ""
                    , listExpr [ strExpr "a", strExpr "b", strExpr "c" ]
                    ]
                )
    in
    expectFn modul


{-| Returns a check of `expectFn` against
`List.map Basics.not [True, False, True]`, which passes `not` by name and
produces a list of `Bool`.
-}
mapWithBoolResult : (Src.Module -> Expectation) -> (() -> Expectation)
mapWithBoolResult expectFn _ =
    let
        modul =
            makeModule "testValue"
                (callExpr (qualVarExpr "List" "map")
                    [ qualVarExpr "Basics" "not"
                    , listExpr [ boolExpr True, boolExpr False, boolExpr True ]
                    ]
                )
    in
    expectFn modul


{-| Returns a check of `expectFn` against `List.reverse [1, 2, 3]`.
-}
listReverse : (Src.Module -> Expectation) -> (() -> Expectation)
listReverse expectFn _ =
    let
        modul =
            makeModule "testValue"
                (callExpr (qualVarExpr "List" "reverse")
                    [ listExpr [ intExpr 1, intExpr 2, intExpr 3 ] ]
                )
    in
    expectFn modul


{-| Returns a check of `expectFn` against `List.length [1, 2, 3]`.
-}
listLength : (Src.Module -> Expectation) -> (() -> Expectation)
listLength expectFn _ =
    let
        modul =
            makeModule "testValue"
                (callExpr (qualVarExpr "List" "length")
                    [ listExpr [ intExpr 1, intExpr 2, intExpr 3 ] ]
                )
    in
    expectFn modul


{-| Returns a check of `expectFn` against `[1, 2, 3] |> List.map double`, where
`double x = x * 2` is defined in a `let`.
-}
pipelineListMap : (Src.Module -> Expectation) -> (() -> Expectation)
pipelineListMap expectFn _ =
    let
        double =
            define "double" [ pVar "x" ] (binopsExpr [ ( varExpr "x", "*" ) ] (intExpr 2))

        modul =
            makeModule "testValue"
                (letExpr [ double ]
                    (binopsExpr
                        [ ( listExpr [ intExpr 1, intExpr 2, intExpr 3 ], "|>" ) ]
                        (callExpr (qualVarExpr "List" "map") [ varExpr "double" ])
                    )
                )
    in
    expectFn modul


{-| Returns a check of `expectFn` against `[1, 2] ++ [3, 4]`.
-}
listConcatViaAppend : (Src.Module -> Expectation) -> (() -> Expectation)
listConcatViaAppend expectFn _ =
    let
        modul =
            makeModule "testValue"
                (binopsExpr
                    [ ( listExpr [ intExpr 1, intExpr 2 ], "++" ) ]
                    (listExpr [ intExpr 3, intExpr 4 ])
                )
    in
    expectFn modul


{-| Returns a check of `expectFn` against `List.map (curried 5) [1, 2, 3]`,
where `curried x = \y -> x + y` is defined in a `let`.

`curried` takes its two arguments in two stages: one parameter, then a lambda
taking the second. Applying it to 5 therefore saturates its first stage and
returns that lambda as a closure, which is what `List.map` receives.

-}
mapWithPartialAppMultiStage : (Src.Module -> Expectation) -> (() -> Expectation)
mapWithPartialAppMultiStage expectFn _ =
    let
        curried =
            define "curried"
                [ pVar "x" ]
                (lambdaExpr [ pVar "y" ] (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "y")))

        modul =
            makeModule "testValue"
                (letExpr [ curried ]
                    (callExpr (qualVarExpr "List" "map")
                        [ callExpr (varExpr "curried") [ intExpr 5 ]
                        , listExpr [ intExpr 1, intExpr 2, intExpr 3 ]
                        ]
                    )
                )
    in
    expectFn modul


{-| Returns a check of `expectFn` against `List.foldl (combine 2) 0 [1, 2, 3]`,
where `combine factor x acc = (factor * x) + acc` is defined in a `let`. The
sketch is written as Elm source: none of its parentheses is a `Parens` node in
the tree.

`combine` takes three arguments; it is applied to one, and the two-argument
function that leaves is the fold's function.

-}
foldlWithPartialAppAccum : (Src.Module -> Expectation) -> (() -> Expectation)
foldlWithPartialAppAccum expectFn _ =
    let
        combine =
            define "combine"
                [ pVar "factor", pVar "x", pVar "acc" ]
                (binopsExpr
                    [ ( binopsExpr [ ( varExpr "factor", "*" ) ] (varExpr "x"), "+" ) ]
                    (varExpr "acc")
                )

        modul =
            makeModule "testValue"
                (letExpr [ combine ]
                    (callExpr (qualVarExpr "List" "foldl")
                        [ callExpr (varExpr "combine") [ intExpr 2 ]
                        , intExpr 0
                        , listExpr [ intExpr 1, intExpr 2, intExpr 3 ]
                        ]
                    )
                )
    in
    expectFn modul


{-| Returns a check of `expectFn` against `List.filter (eq 5) [1, 2, 5, 3, 5]`,
where `eq a b = a == b` is defined in a `let`.

The partially applied function is the named wrapper `eq`, not the operator
`(==)`.

-}
filterWithPartialEq : (Src.Module -> Expectation) -> (() -> Expectation)
filterWithPartialEq expectFn _ =
    let
        eqFn =
            define "eq"
                [ pVar "a", pVar "b" ]
                (binopsExpr [ ( varExpr "a", "==" ) ] (varExpr "b"))

        modul =
            makeModule "testValue"
                (letExpr [ eqFn ]
                    (callExpr (qualVarExpr "List" "filter")
                        [ callExpr (varExpr "eq") [ intExpr 5 ]
                        , listExpr [ intExpr 1, intExpr 2, intExpr 5, intExpr 3, intExpr 5 ]
                        ]
                    )
                )
    in
    expectFn modul
