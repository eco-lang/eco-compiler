module SourceIR.KernelPipelineCases exposing (expectSuite)

{-| Test cases that exercise kernel code compilation through the full pipeline.

Uses Source AST with qualVarExpr to reference standard library functions
(Basics, List, Tuple, etc.) which are resolved via test interfaces and
become VarKernel nodes after canonicalization.

This exercises PostSolve kernel type inference, Monomorphize kernel ABI
derivation, and MLIR kernel intrinsic generation.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , binopsExpr
        , boolExpr
        , callExpr
        , caseExpr
        , chrExpr
        , define
        , floatExpr
        , ifExpr
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeKernelModule
        , makeModule
        , makeModuleWithDefs
        , makeModuleWithTypedDefs
        , pAnything
        , pCons
        , pCtor
        , pInt
        , pList
        , pVar
        , qualVarExpr
        , recordExpr
        , strExpr
        , tLambda
        , tType
        , tVar
        , tupleExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Kernel pipeline " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.concat
        [ basicsKernelCases expectFn
        , listKernelCases expectFn
        , tupleKernelCases expectFn
        , bitwiseKernelCases expectFn
        , comparisonKernelCases expectFn
        , higherOrderKernelCases expectFn
        ]



-- ============================================================================
-- BASICS KERNEL FUNCTIONS
-- ============================================================================


basicsKernelCases : (Src.Module -> Expectation) -> List TestCase
basicsKernelCases expectFn =
    [ { label = "Basics.abs on Int", run = basicsAbs expectFn }
    , { label = "Basics.negate on Int", run = basicsNegate expectFn }
    , { label = "Basics.toFloat", run = basicsToFloat expectFn }
    , { label = "Basics.round", run = basicsRound expectFn }
    , { label = "Basics.identity", run = basicsIdentity expectFn }
    , { label = "Basics.always", run = basicsAlways expectFn }
    , { label = "Basics.not on Bool", run = basicsNot expectFn }
    , { label = "Basics.max on Int", run = basicsMax expectFn }
    , { label = "Basics.min on Int", run = basicsMin expectFn }
    , { label = "Basics.clamp", run = basicsClamp expectFn }
    , { label = "Basics.remainderBy", run = basicsRemainderBy expectFn }
    , { label = "Basics.sqrt", run = basicsSqrt expectFn }
    , { label = "Basics.sin", run = basicsSin expectFn }
    , { label = "Arithmetic operators", run = arithmeticOps expectFn }
    , { label = "Float division", run = floatDivision expectFn }
    , { label = "Integer division", run = integerDivision expectFn }
    , { label = "Power operator", run = powerOp expectFn }
    , { label = "Pipe operators", run = pipeOperators expectFn }
    ]


basicsAbs : (Src.Module -> Expectation) -> (() -> Expectation)
basicsAbs expectFn _ =
    expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Basics" "abs") [ intExpr -5 ]))


basicsNegate : (Src.Module -> Expectation) -> (() -> Expectation)
basicsNegate expectFn _ =
    expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Basics" "negate") [ intExpr 42 ]))


basicsToFloat : (Src.Module -> Expectation) -> (() -> Expectation)
basicsToFloat expectFn _ =
    expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Basics" "toFloat") [ intExpr 5 ]))


basicsRound : (Src.Module -> Expectation) -> (() -> Expectation)
basicsRound expectFn _ =
    expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Basics" "round") [ floatExpr 3.7 ]))


basicsIdentity : (Src.Module -> Expectation) -> (() -> Expectation)
basicsIdentity expectFn _ =
    expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Basics" "identity") [ intExpr 99 ]))


basicsAlways : (Src.Module -> Expectation) -> (() -> Expectation)
basicsAlways expectFn _ =
    expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Basics" "always") [ intExpr 1, strExpr "ignored" ]))


basicsNot : (Src.Module -> Expectation) -> (() -> Expectation)
basicsNot expectFn _ =
    expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Basics" "not") [ boolExpr True ]))


basicsMax : (Src.Module -> Expectation) -> (() -> Expectation)
basicsMax expectFn _ =
    expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Basics" "max") [ intExpr 3, intExpr 7 ]))


basicsMin : (Src.Module -> Expectation) -> (() -> Expectation)
basicsMin expectFn _ =
    expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Basics" "min") [ intExpr 3, intExpr 7 ]))


basicsClamp : (Src.Module -> Expectation) -> (() -> Expectation)
basicsClamp expectFn _ =
    expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Basics" "clamp") [ intExpr 0, intExpr 10, intExpr 15 ]))


basicsRemainderBy : (Src.Module -> Expectation) -> (() -> Expectation)
basicsRemainderBy expectFn _ =
    expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Basics" "remainderBy") [ intExpr 3, intExpr 10 ]))


basicsSqrt : (Src.Module -> Expectation) -> (() -> Expectation)
basicsSqrt expectFn _ =
    expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Basics" "sqrt") [ floatExpr 25.0 ]))


basicsSin : (Src.Module -> Expectation) -> (() -> Expectation)
basicsSin expectFn _ =
    expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Basics" "sin") [ floatExpr 0.0 ]))


arithmeticOps : (Src.Module -> Expectation) -> (() -> Expectation)
arithmeticOps expectFn _ =
    let
        modul =
            makeKernelModule "testValue"
                (letExpr
                    [ define "a" [] (binopsExpr [ ( intExpr 3, "+" ) ] (intExpr 4))
                    , define "b" [] (binopsExpr [ ( intExpr 10, "-" ) ] (intExpr 3))
                    , define "c" [] (binopsExpr [ ( intExpr 6, "*" ) ] (intExpr 7))
                    ]
                    (binopsExpr [ ( varExpr "a", "+" ), ( varExpr "b", "+" ) ] (varExpr "c"))
                )
    in
    expectFn modul


floatDivision : (Src.Module -> Expectation) -> (() -> Expectation)
floatDivision expectFn _ =
    expectFn (makeKernelModule "testValue" (binopsExpr [ ( floatExpr 10.0, "/" ) ] (floatExpr 3.0)))


integerDivision : (Src.Module -> Expectation) -> (() -> Expectation)
integerDivision expectFn _ =
    expectFn (makeKernelModule "testValue" (binopsExpr [ ( intExpr 10, "//" ) ] (intExpr 3)))


powerOp : (Src.Module -> Expectation) -> (() -> Expectation)
powerOp expectFn _ =
    expectFn (makeKernelModule "testValue" (binopsExpr [ ( intExpr 2, "^" ) ] (intExpr 10)))


pipeOperators : (Src.Module -> Expectation) -> (() -> Expectation)
pipeOperators expectFn _ =
    let
        modul =
            makeKernelModule "testValue"
                (binopsExpr
                    [ ( intExpr 5, "|>" ) ]
                    (qualVarExpr "Basics" "abs")
                )
    in
    expectFn modul



-- ============================================================================
-- LIST KERNEL FUNCTIONS
-- ============================================================================


listKernelCases : (Src.Module -> Expectation) -> List TestCase
listKernelCases expectFn =
    [ { label = "List.map", run = listMap expectFn }
    , { label = "List.foldl", run = listFoldl expectFn }
    , { label = "List.foldr", run = listFoldr expectFn }
    , { label = "List.reverse", run = listReverse expectFn }
    , { label = "List.length", run = listLength expectFn }
    , { label = "List.concat", run = listConcat expectFn }
    , { label = "List.range", run = listRange expectFn }
    , { label = "List.drop", run = listDrop expectFn }
    , { label = "List.cons", run = listCons expectFn }
    , { label = "List.map2", run = listMap2 expectFn }
    , { label = ":: cons operator", run = consOperator expectFn }
    ]


listMap : (Src.Module -> Expectation) -> (() -> Expectation)
listMap expectFn _ =
    let
        modul =
            makeKernelModule "testValue"
                (callExpr (qualVarExpr "List" "map")
                    [ lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1))
                    , listExpr [ intExpr 1, intExpr 2, intExpr 3 ]
                    ]
                )
    in
    expectFn modul


listFoldl : (Src.Module -> Expectation) -> (() -> Expectation)
listFoldl expectFn _ =
    let
        modul =
            makeKernelModule "testValue"
                (callExpr (qualVarExpr "List" "foldl")
                    [ lambdaExpr [ pVar "x", pVar "acc" ] (binopsExpr [ ( varExpr "acc", "+" ) ] (varExpr "x"))
                    , intExpr 0
                    , listExpr [ intExpr 1, intExpr 2, intExpr 3 ]
                    ]
                )
    in
    expectFn modul


listFoldr : (Src.Module -> Expectation) -> (() -> Expectation)
listFoldr expectFn _ =
    let
        modul =
            makeKernelModule "testValue"
                (callExpr (qualVarExpr "List" "foldr")
                    [ lambdaExpr [ pVar "x", pVar "acc" ] (binopsExpr [ ( varExpr "x", "::" ) ] (varExpr "acc"))
                    , listExpr []
                    , listExpr [ intExpr 1, intExpr 2, intExpr 3 ]
                    ]
                )
    in
    expectFn modul


listReverse : (Src.Module -> Expectation) -> (() -> Expectation)
listReverse expectFn _ =
    expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "List" "reverse") [ listExpr [ intExpr 3, intExpr 2, intExpr 1 ] ]))


listLength : (Src.Module -> Expectation) -> (() -> Expectation)
listLength expectFn _ =
    expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "List" "length") [ listExpr [ intExpr 1, intExpr 2 ] ]))


listConcat : (Src.Module -> Expectation) -> (() -> Expectation)
listConcat expectFn _ =
    let
        modul =
            makeKernelModule "testValue"
                (callExpr (qualVarExpr "List" "concat")
                    [ listExpr
                        [ listExpr [ intExpr 1, intExpr 2 ]
                        , listExpr [ intExpr 3, intExpr 4 ]
                        ]
                    ]
                )
    in
    expectFn modul


listRange : (Src.Module -> Expectation) -> (() -> Expectation)
listRange expectFn _ =
    expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "List" "range") [ intExpr 1, intExpr 5 ]))


listDrop : (Src.Module -> Expectation) -> (() -> Expectation)
listDrop expectFn _ =
    expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "List" "drop") [ intExpr 2, listExpr [ intExpr 1, intExpr 2, intExpr 3 ] ]))


listCons : (Src.Module -> Expectation) -> (() -> Expectation)
listCons expectFn _ =
    expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "List" "cons") [ intExpr 0, listExpr [ intExpr 1, intExpr 2 ] ]))


listMap2 : (Src.Module -> Expectation) -> (() -> Expectation)
listMap2 expectFn _ =
    let
        modul =
            makeKernelModule "testValue"
                (callExpr (qualVarExpr "List" "map2")
                    [ lambdaExpr [ pVar "a", pVar "b" ] (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b"))
                    , listExpr [ intExpr 1, intExpr 2 ]
                    , listExpr [ intExpr 10, intExpr 20 ]
                    ]
                )
    in
    expectFn modul


consOperator : (Src.Module -> Expectation) -> (() -> Expectation)
consOperator expectFn _ =
    expectFn (makeKernelModule "testValue" (binopsExpr [ ( intExpr 0, "::" ) ] (listExpr [ intExpr 1, intExpr 2 ])))



-- ============================================================================
-- TUPLE KERNEL FUNCTIONS
-- ============================================================================


tupleKernelCases : (Src.Module -> Expectation) -> List TestCase
tupleKernelCases expectFn =
    [ { label = "Tuple.pair", run = tuplePair expectFn }
    , { label = "Tuple.first", run = tupleFirst expectFn }
    , { label = "Tuple.second", run = tupleSecond expectFn }
    , { label = "Tuple.mapFirst", run = tupleMapFirst expectFn }
    , { label = "Tuple.mapSecond", run = tupleMapSecond expectFn }
    ]


tuplePair : (Src.Module -> Expectation) -> (() -> Expectation)
tuplePair expectFn _ =
    expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Tuple" "pair") [ intExpr 1, strExpr "hello" ]))


tupleFirst : (Src.Module -> Expectation) -> (() -> Expectation)
tupleFirst expectFn _ =
    expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Tuple" "first") [ tupleExpr (intExpr 1) (strExpr "hi") ]))


tupleSecond : (Src.Module -> Expectation) -> (() -> Expectation)
tupleSecond expectFn _ =
    expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Tuple" "second") [ tupleExpr (intExpr 1) (strExpr "hi") ]))


tupleMapFirst : (Src.Module -> Expectation) -> (() -> Expectation)
tupleMapFirst expectFn _ =
    let
        modul =
            makeKernelModule "testValue"
                (callExpr (qualVarExpr "Tuple" "mapFirst")
                    [ lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1))
                    , tupleExpr (intExpr 5) (strExpr "hi")
                    ]
                )
    in
    expectFn modul


tupleMapSecond : (Src.Module -> Expectation) -> (() -> Expectation)
tupleMapSecond expectFn _ =
    let
        modul =
            makeKernelModule "testValue"
                (callExpr (qualVarExpr "Tuple" "mapSecond")
                    [ lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "++" ) ] (strExpr "!"))
                    , tupleExpr (intExpr 5) (strExpr "hi")
                    ]
                )
    in
    expectFn modul



-- ============================================================================
-- BITWISE KERNEL FUNCTIONS
-- ============================================================================


bitwiseKernelCases : (Src.Module -> Expectation) -> List TestCase
bitwiseKernelCases expectFn =
    [ { label = "Bitwise.and", run = bitwiseAnd expectFn }
    , { label = "Bitwise.or", run = bitwiseOr expectFn }
    , { label = "Bitwise.xor", run = bitwiseXor expectFn }
    , { label = "Bitwise.shiftLeftBy", run = bitwiseShiftLeft expectFn }
    ]


bitwiseAnd : (Src.Module -> Expectation) -> (() -> Expectation)
bitwiseAnd expectFn _ =
    expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Bitwise" "and") [ intExpr 255, intExpr 15 ]))


bitwiseOr : (Src.Module -> Expectation) -> (() -> Expectation)
bitwiseOr expectFn _ =
    expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Bitwise" "or") [ intExpr 240, intExpr 15 ]))


bitwiseXor : (Src.Module -> Expectation) -> (() -> Expectation)
bitwiseXor expectFn _ =
    expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Bitwise" "xor") [ intExpr 255, intExpr 15 ]))


bitwiseShiftLeft : (Src.Module -> Expectation) -> (() -> Expectation)
bitwiseShiftLeft expectFn _ =
    expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Bitwise" "shiftLeftBy") [ intExpr 4, intExpr 1 ]))



-- ============================================================================
-- COMPARISON KERNEL FUNCTIONS
-- ============================================================================


comparisonKernelCases : (Src.Module -> Expectation) -> List TestCase
comparisonKernelCases expectFn =
    [ { label = "Int comparison operators", run = intComparisons expectFn }
    , { label = "Float comparison", run = floatComparison expectFn }
    , { label = "String equality", run = stringEquality expectFn }
    , { label = "Bool logical operators", run = boolLogical expectFn }
    , { label = "Char equality", run = charEquality expectFn }
    ]


intComparisons : (Src.Module -> Expectation) -> (() -> Expectation)
intComparisons expectFn _ =
    let
        modul =
            makeKernelModule "testValue"
                (letExpr
                    [ define "lt" [] (binopsExpr [ ( intExpr 1, "<" ) ] (intExpr 2))
                    , define "gt" [] (binopsExpr [ ( intExpr 2, ">" ) ] (intExpr 1))
                    , define "le" [] (binopsExpr [ ( intExpr 1, "<=" ) ] (intExpr 1))
                    , define "ge" [] (binopsExpr [ ( intExpr 1, ">=" ) ] (intExpr 1))
                    , define "eq" [] (binopsExpr [ ( intExpr 1, "==" ) ] (intExpr 1))
                    , define "ne" [] (binopsExpr [ ( intExpr 1, "/=" ) ] (intExpr 2))
                    ]
                    (varExpr "lt")
                )
    in
    expectFn modul


floatComparison : (Src.Module -> Expectation) -> (() -> Expectation)
floatComparison expectFn _ =
    expectFn (makeKernelModule "testValue" (binopsExpr [ ( floatExpr 1.5, "<" ) ] (floatExpr 2.5)))


stringEquality : (Src.Module -> Expectation) -> (() -> Expectation)
stringEquality expectFn _ =
    expectFn (makeKernelModule "testValue" (binopsExpr [ ( strExpr "hello", "==" ) ] (strExpr "world")))


boolLogical : (Src.Module -> Expectation) -> (() -> Expectation)
boolLogical expectFn _ =
    let
        modul =
            makeKernelModule "testValue"
                (letExpr
                    [ define "a" [] (binopsExpr [ ( boolExpr True, "&&" ) ] (boolExpr False))
                    , define "b" [] (binopsExpr [ ( boolExpr True, "||" ) ] (boolExpr False))
                    ]
                    (varExpr "a")
                )
    in
    expectFn modul


charEquality : (Src.Module -> Expectation) -> (() -> Expectation)
charEquality expectFn _ =
    expectFn (makeKernelModule "testValue" (binopsExpr [ ( chrExpr "a", "==" ) ] (chrExpr "b")))



-- ============================================================================
-- HIGHER-ORDER KERNEL USAGE
-- ============================================================================


higherOrderKernelCases : (Src.Module -> Expectation) -> List TestCase
higherOrderKernelCases expectFn =
    [ { label = "List.map with Basics.negate", run = mapWithNegate expectFn }
    , { label = "List.foldl for sum", run = foldlSum expectFn }
    , { label = "Chained List.map and List.reverse", run = chainedListOps expectFn }
    , { label = "List.map on List of tuples", run = mapOnTuples expectFn }
    , { label = "Nested List.map", run = nestedMap expectFn }
    ]


mapWithNegate : (Src.Module -> Expectation) -> (() -> Expectation)
mapWithNegate expectFn _ =
    let
        modul =
            makeKernelModule "testValue"
                (callExpr (qualVarExpr "List" "map")
                    [ qualVarExpr "Basics" "negate"
                    , listExpr [ intExpr 1, intExpr 2, intExpr 3 ]
                    ]
                )
    in
    expectFn modul


foldlSum : (Src.Module -> Expectation) -> (() -> Expectation)
foldlSum expectFn _ =
    let
        modul =
            makeKernelModule "testValue"
                (callExpr (qualVarExpr "List" "foldl")
                    [ lambdaExpr [ pVar "x", pVar "acc" ] (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "acc"))
                    , intExpr 0
                    , callExpr (qualVarExpr "List" "range") [ intExpr 1, intExpr 10 ]
                    ]
                )
    in
    expectFn modul


chainedListOps : (Src.Module -> Expectation) -> (() -> Expectation)
chainedListOps expectFn _ =
    let
        modul =
            makeKernelModule "testValue"
                (callExpr (qualVarExpr "List" "reverse")
                    [ callExpr (qualVarExpr "List" "map")
                        [ lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "*" ) ] (intExpr 2))
                        , listExpr [ intExpr 1, intExpr 2, intExpr 3 ]
                        ]
                    ]
                )
    in
    expectFn modul


mapOnTuples : (Src.Module -> Expectation) -> (() -> Expectation)
mapOnTuples expectFn _ =
    let
        modul =
            makeKernelModule "testValue"
                (callExpr (qualVarExpr "List" "map")
                    [ qualVarExpr "Tuple" "first"
                    , listExpr
                        [ tupleExpr (intExpr 1) (strExpr "a")
                        , tupleExpr (intExpr 2) (strExpr "b")
                        ]
                    ]
                )
    in
    expectFn modul


nestedMap : (Src.Module -> Expectation) -> (() -> Expectation)
nestedMap expectFn _ =
    let
        modul =
            makeKernelModule "testValue"
                (callExpr (qualVarExpr "List" "map")
                    [ lambdaExpr [ pVar "xs" ]
                        (callExpr (qualVarExpr "List" "map")
                            [ lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1))
                            , varExpr "xs"
                            ]
                        )
                    , listExpr
                        [ listExpr [ intExpr 1, intExpr 2 ]
                        , listExpr [ intExpr 3, intExpr 4 ]
                        ]
                    ]
                )
    in
    expectFn modul
