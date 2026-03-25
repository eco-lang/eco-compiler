module SourceIR.KernelHigherOrderCases exposing (expectSuite)

{-| Kernel higher-order tests — kernel functions as arguments, composed with
other kernels.
-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder exposing (binopsExpr, boolExpr, callExpr, define, intExpr, lambdaExpr, letExpr, listExpr, makeKernelModule, makeModule, pVar, qualVarExpr, strExpr, tupleExpr, varExpr)
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Kernel higher-order " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


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


{-| List.map with a user-defined named function (not a kernel function).
Mirrors ListMapTest.elm: `List.map double [1, 2, 3]` where `double x = x * 2`.
The function reference creates a PAP when passed to the kernel map.
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


{-| List.map with an inline anonymous lambda.
Mirrors AnonymousFunctionTest.elm: `List.map (\x -> x * 2) [1, 2, 3]`.
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


{-| List.map with a partially applied user function.
Mirrors PartialApplicationTest.elm: `List.map (add 1) [1, 2, 3]`.
The partial application creates a PAP that is then passed as a closure to map.
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


{-| List.filter with a user-defined predicate.
Mirrors ListFilterTest.elm: `List.filter isPositive [-1, 0, 1, 2, 3]`.
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


{-| List.foldl with a 2-arg lambda wrapping (+).
Mirrors ListFoldlTest.elm: `List.foldl (+) 0 [1, 2, 3, 4]`.
In source IR, operator sections are represented as lambdas wrapping binops.
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


{-| List.foldr with a 2-arg lambda wrapping (++).
Mirrors ListFoldrTest.elm: `List.foldr (++) "" ["a", "b", "c"]`.
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


{-| List.map producing Bool results via a negation lambda.
Mirrors ListMapBoolTest.elm: `List.map not [True, False, True]`.
Bool is always eco.value in heap storage, exercises boxing path.
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


{-| List.reverse exercises kernel HOF internals.
Mirrors ListReverseTest.elm: `List.reverse [1, 2, 3]`.
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


{-| List.length exercises kernel internals.
Mirrors ListLengthTest.elm: `List.length [1, 2, 3]`.
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


{-| Pipeline with List.map.
Mirrors PipelineTest.elm: `[1, 2, 3] |> List.map double`.
The pipe operator desugars to apR which creates PAP chains.
-}
pipelineListMap : (Src.Module -> Expectation) -> (() -> Expectation)
pipelineListMap expectFn _ =
    let
        double =
            define "double" [ pVar "x" ] (binopsExpr [ ( varExpr "x", "*" ) ] (intExpr 2))

        -- |> desugars to: apR value func = func value
        -- So `[1,2,3] |> List.map double` becomes:
        -- apR [1,2,3] (List.map double)
        -- Which is: (List.map double) [1,2,3]
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


{-| List concatenation via (++) operator.
Mirrors ListConcatTest.elm: `[1, 2] ++ [3, 4]`.
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


{-| List.map with a partially applied multi-stage function.
Mirrors PapExtendArityTest.elm: A function `curried x = \y -> x + y` is
partially applied and passed to a higher-order function. The multi-stage
type (MFunction [Int] (MFunction [Int] Int)) can cause sourceArityForCallee
to miscalculate when falling back to countTotalArityFromType.
-}
mapWithPartialAppMultiStage : (Src.Module -> Expectation) -> (() -> Expectation)
mapWithPartialAppMultiStage expectFn _ =
    let
        -- curried x = \y -> x + y  (multi-stage: Int -> (Int -> Int))
        curried =
            define "curried"
                [ pVar "x" ]
                (lambdaExpr [ pVar "y" ] (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "y")))

        -- List.map (curried 5) [1, 2, 3]  — curried 5 returns a closure
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


{-| List.foldl with a partial application of a 3-arg function as accumulator fn.
Exercises PAP chain: 3-arg function partially applied with 1 arg, then passed
as a 2-arg callback to foldl.
-}
foldlWithPartialAppAccum : (Src.Module -> Expectation) -> (() -> Expectation)
foldlWithPartialAppAccum expectFn _ =
    let
        -- combine factor x acc = factor * x + acc
        combine =
            define "combine"
                [ pVar "factor", pVar "x", pVar "acc" ]
                (binopsExpr
                    [ ( binopsExpr [ ( varExpr "factor", "*" ) ] (varExpr "x"), "+" ) ]
                    (varExpr "acc")
                )

        -- List.foldl (combine 2) 0 [1, 2, 3]
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


{-| List.filter with a partially applied equality check.
Mirrors EqualityCharPapTest.elm: `List.filter (eq 5) [1, 2, 5, 3, 5]`
where `eq = (==)` is used as a function value.
-}
filterWithPartialEq : (Src.Module -> Expectation) -> (() -> Expectation)
filterWithPartialEq expectFn _ =
    let
        -- eq a b = a == b (wrapping the operator)
        eqFn =
            define "eq"
                [ pVar "a", pVar "b" ]
                (binopsExpr [ ( varExpr "a", "==" ) ] (varExpr "b"))

        -- List.filter (eq 5) [1, 2, 5, 3, 5]
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
