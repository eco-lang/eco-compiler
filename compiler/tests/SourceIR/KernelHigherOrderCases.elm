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
`Compiler.Canonicalize.Expression`); elsewhere it is not found. The other
fourteen call the `List` and `Basics` functions in a module built with
`makeModule`, which imports only `Basics` and `List`. `List.reverse`,
`List.length` and `++` take no function argument.

The programs, one per case, in the order they run:

  - `Elm.Kernel.List.map Elm.Kernel.Basics.negate [1, 2, 3]`.
  - `Elm.Kernel.List.foldl (\x acc -> x + acc) 0 (Elm.Kernel.List.range 1 10)`.
  - `Elm.Kernel.List.map Elm.Kernel.Tuple.first [(1, "a"), (2, "b")]`.
  - `Elm.Kernel.List.map` of a lambda that itself calls
    `Elm.Kernel.List.map (\x -> x + 1)`, over `[[1, 2], [3, 4]]`.
  - `Elm.Kernel.List.foldl Elm.Kernel.Basics.add 0 [1, 2, 3]`.
  - `List.map double [1, 2, 3]`, with `double x = x * 2` defined in a `let`.
  - `List.map (\x -> x * 2) [1, 2, 3]`.
  - `List.map addOne [1, 2, 3]`, with `add a b = a + b` and `addOne = add 1`
    defined in a `let`.
  - `List.filter isPositive [1, 2, 3, 4, 5]`, with `isPositive x = x > 0`
    defined in a `let`.
  - `List.foldl (\a b -> a + b) 0 [1, 2, 3, 4]`.
  - `List.foldr (\a b -> a ++ b) "" ["a", "b", "c"]`.
  - `List.map Basics.not [True, False, True]`.
  - `List.reverse [1, 2, 3]`.
  - `List.length [1, 2, 3]`.
  - `(List.map double) [1, 2, 3]`, a call whose function is itself a call.
  - `[1, 2] ++ [3, 4]`.
  - `List.map (curried 5) [1, 2, 3]`, with `curried x = \y -> x + y`.
  - `List.foldl (combine 2) 0 [1, 2, 3]`, with
    `combine factor x acc = (factor * x) + acc`.
  - `List.filter (eq 5) [1, 2, 5, 3, 5]`, with `eq a b = a == b`.

Among what is not tested: an operator passed as a value, such as `(+)` (the
two fold cases labelled as operators pass a lambda), the `|>` operator (the
case labelled "Pipeline" has none), `(==)` partially applied directly, and the
`List` functions over more than one list, such as `List.map2`.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder exposing (binopsExpr, boolExpr, callExpr, define, intExpr, lambdaExpr, letExpr, listExpr, makeKernelModule, makeModule, pVar, qualVarExpr, strExpr, tupleExpr, varExpr)
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
    [ { label = "List.map with Basics.negate", run = mapWithNegate expectFn }
    , { label = "List.foldl for sum", run = foldlSum expectFn }
    , { label = "List.map on tuples with Tuple.first", run = mapOnTuples expectFn }
    , { label = "Nested List.map", run = nestedMap expectFn }
    , { label = "List.foldl with kernel add", run = foldlWithKernelAdd expectFn }
    , { label = "List.map with user-defined function", run = mapWithUserFunction expectFn }
    , { label = "List.map with anonymous lambda", run = mapWithAnonymousLambda expectFn }
    , { label = "List.map with partial application", run = mapWithPartialApplication expectFn }
    , { label = "List.filter with user predicate", run = filterWithUserPredicate expectFn }
    , { label = "List.foldl with operator as value", run = foldlWithOperatorValue expectFn }
    , { label = "List.foldr with string append operator", run = foldrWithStringAppend expectFn }
    , { label = "List.map with Bool result", run = mapWithBoolResult expectFn }
    , { label = "List.reverse via kernel", run = listReverseViaKernel expectFn }
    , { label = "List.length via kernel", run = listLengthViaKernel expectFn }
    , { label = "Pipeline List.map", run = pipelineListMap expectFn }
    , { label = "List.concat via append", run = listConcatViaAppend expectFn }
    , { label = "List.map with partial app of multi-stage fn", run = mapWithPartialAppMultiStage expectFn }
    , { label = "List.foldl with partial app accumulator", run = foldlWithPartialAppAccum expectFn }
    , { label = "List.filter with partially applied equality", run = filterWithPartialEq expectFn }
    ]


{-| Returns a check of `expectFn` against
`Elm.Kernel.List.map Elm.Kernel.Basics.negate [1, 2, 3]`.
-}
mapWithNegate : (Src.Module -> Expectation) -> (() -> Expectation)
mapWithNegate expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Elm.Kernel.List" "map")
                [ qualVarExpr "Elm.Kernel.Basics" "negate"
                , listExpr [ intExpr 1, intExpr 2, intExpr 3 ]
                ]
            )
        )


{-| Returns a check of `expectFn` against
`Elm.Kernel.List.foldl (\x acc -> x + acc) 0 (Elm.Kernel.List.range 1 10)`.
-}
foldlSum : (Src.Module -> Expectation) -> (() -> Expectation)
foldlSum expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Elm.Kernel.List" "foldl")
                [ lambdaExpr [ pVar "x", pVar "acc" ] (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "acc"))
                , intExpr 0
                , callExpr (qualVarExpr "Elm.Kernel.List" "range") [ intExpr 1, intExpr 10 ]
                ]
            )
        )


{-| Returns a check of `expectFn` against
`Elm.Kernel.List.map Elm.Kernel.Tuple.first [(1, "a"), (2, "b")]`.
-}
mapOnTuples : (Src.Module -> Expectation) -> (() -> Expectation)
mapOnTuples expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Elm.Kernel.List" "map")
                [ qualVarExpr "Elm.Kernel.Tuple" "first"
                , listExpr [ tupleExpr (intExpr 1) (strExpr "a"), tupleExpr (intExpr 2) (strExpr "b") ]
                ]
            )
        )


{-| Returns a check of `expectFn` against an `Elm.Kernel.List.map` call whose
function is a lambda over `xs` making a second `Elm.Kernel.List.map` call with
`\x -> x + 1` and `xs`, over `[[1, 2], [3, 4]]`.
-}
nestedMap : (Src.Module -> Expectation) -> (() -> Expectation)
nestedMap expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Elm.Kernel.List" "map")
                [ lambdaExpr [ pVar "xs" ]
                    (callExpr (qualVarExpr "Elm.Kernel.List" "map")
                        [ lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1))
                        , varExpr "xs"
                        ]
                    )
                , listExpr [ listExpr [ intExpr 1, intExpr 2 ], listExpr [ intExpr 3, intExpr 4 ] ]
                ]
            )
        )


{-| Returns a check of `expectFn` against
`Elm.Kernel.List.foldl Elm.Kernel.Basics.add 0 [1, 2, 3]`.
-}
foldlWithKernelAdd : (Src.Module -> Expectation) -> (() -> Expectation)
foldlWithKernelAdd expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Elm.Kernel.List" "foldl")
                [ qualVarExpr "Elm.Kernel.Basics" "add"
                , intExpr 0
                , listExpr [ intExpr 1, intExpr 2, intExpr 3 ]
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
                        , listExpr [ intExpr 1, intExpr 2, intExpr 3, intExpr 4, intExpr 5 ]
                        ]
                    )
                )
    in
    expectFn modul


{-| Returns a check of `expectFn` against
`List.foldl (\a b -> a + b) 0 [1, 2, 3, 4]`.

The function is a lambda around `+`, not the operator `(+)` used as a value,
although the label says otherwise.

-}
foldlWithOperatorValue : (Src.Module -> Expectation) -> (() -> Expectation)
foldlWithOperatorValue expectFn _ =
    let
        modul =
            makeModule "testValue"
                (callExpr (qualVarExpr "List" "foldl")
                    [ lambdaExpr [ pVar "a", pVar "b" ] (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b"))
                    , intExpr 0
                    , listExpr [ intExpr 1, intExpr 2, intExpr 3, intExpr 4 ]
                    ]
                )
    in
    expectFn modul


{-| Returns a check of `expectFn` against
`List.foldr (\a b -> a ++ b) "" ["a", "b", "c"]`, where the function is a
lambda around `++`.
-}
foldrWithStringAppend : (Src.Module -> Expectation) -> (() -> Expectation)
foldrWithStringAppend expectFn _ =
    let
        modul =
            makeModule "testValue"
                (callExpr (qualVarExpr "List" "foldr")
                    [ lambdaExpr [ pVar "a", pVar "b" ] (binopsExpr [ ( varExpr "a", "++" ) ] (varExpr "b"))
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
listReverseViaKernel : (Src.Module -> Expectation) -> (() -> Expectation)
listReverseViaKernel expectFn _ =
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
listLengthViaKernel : (Src.Module -> Expectation) -> (() -> Expectation)
listLengthViaKernel expectFn _ =
    let
        modul =
            makeModule "testValue"
                (callExpr (qualVarExpr "List" "length")
                    [ listExpr [ intExpr 1, intExpr 2, intExpr 3 ] ]
                )
    in
    expectFn modul


{-| Returns a check of `expectFn` against `(List.map double) [1, 2, 3]`, where
`double x = x * 2` is defined in a `let`.

The program contains no `|>`. It is a call whose function is the call
`List.map double`.

-}
pipelineListMap : (Src.Module -> Expectation) -> (() -> Expectation)
pipelineListMap expectFn _ =
    let
        double =
            define "double" [ pVar "x" ] (binopsExpr [ ( varExpr "x", "*" ) ] (intExpr 2))

        modul =
            makeModule "testValue"
                (letExpr [ double ]
                    (callExpr
                        (callExpr (qualVarExpr "List" "map") [ varExpr "double" ])
                        [ listExpr [ intExpr 1, intExpr 2, intExpr 3 ] ]
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
