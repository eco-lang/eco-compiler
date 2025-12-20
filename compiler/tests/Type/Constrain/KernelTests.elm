module Type.Constrain.KernelTests exposing (suite)

{-| Tests for kernel function expressions (VarKernel).

Kernel functions are references to JavaScript implementations like
Elm.Kernel.Platform.batch. These need special handling because they
have no Elm source code to type-check - we trust the type annotation.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.CanonicalBuilder
    exposing
        ( callExpr
        , funType
        , intExpr
        , intType
        , lambdaExpr
        , letExpr
        , listExpr
        , listType
        , makeDef
        , makeModule
        , makeModuleWithDecls
        , makeTypedDef
        , pVar
        , tupleExpr
        , tupleType
        , varKernelExpr
        , varLocalExpr
        , varType
        )
import Fuzz
import Test exposing (Test)
import Type.Constrain.Shared exposing (expectEquivalentTypeChecking)


suite : Test
suite =
    Test.describe "Kernel function expressions"
        [ simpleKernelTests
        , kernelCallingTests
        , kernelWrapperTests
        , kernelHigherOrderTests
        , varKernelExprTests
        , varKernelCallTests
        , varKernelContextTests
        , varKernelFuzzTests
        ]



-- ============================================================================
-- SIMPLE KERNEL FUNCTION DEFINITIONS
-- ============================================================================


simpleKernelTests : Test
simpleKernelTests =
    Test.describe "Simple kernel definitions"
        [ Test.test "Simple typed kernel assignment types check equivalently" <|
            \_ ->
                let
                    -- batch : List a -> List a
                    -- batch = Elm.Kernel.List.batch
                    batchDef =
                        makeTypedDef "batch"
                            []
                            (varKernelExpr 2 "List" "batch")
                            (funType (listType (varType "a")) (listType (varType "a")))

                    modul =
                        makeModuleWithDecls
                            (Can.Declare batchDef Can.SaveTheEnvironment)
                in
                expectEquivalentTypeChecking modul
        , Test.test "Kernel function with concrete return type types check equivalently" <|
            \_ ->
                let
                    -- getTime : Int
                    -- getTime = Elm.Kernel.Time.now
                    getTimeDef =
                        makeTypedDef "getTime"
                            []
                            (varKernelExpr 2 "Time" "now")
                            intType

                    modul =
                        makeModuleWithDecls
                            (Can.Declare getTimeDef Can.SaveTheEnvironment)
                in
                expectEquivalentTypeChecking modul
        , Test.test "Polymorphic map kernel types check equivalently" <|
            \_ ->
                let
                    -- map : (a -> b) -> List a -> List b
                    -- map = Elm.Kernel.List.map
                    mapDef =
                        makeTypedDef "map"
                            []
                            (varKernelExpr 2 "List" "map")
                            (funType
                                (funType (varType "a") (varType "b"))
                                (funType (listType (varType "a")) (listType (varType "b")))
                            )

                    modul =
                        makeModuleWithDecls
                            (Can.Declare mapDef Can.SaveTheEnvironment)
                in
                expectEquivalentTypeChecking modul
        , Test.test "Kernel function returning tuple types check equivalently" <|
            \_ ->
                let
                    -- pair : a -> b -> (a, b)
                    -- pair = Elm.Kernel.Tuple.pair
                    pairDef =
                        makeTypedDef "pair"
                            []
                            (varKernelExpr 2 "Tuple" "pair")
                            (funType (varType "a")
                                (funType (varType "b") (tupleType (varType "a") (varType "b") []))
                            )

                    modul =
                        makeModuleWithDecls
                            (Can.Declare pairDef Can.SaveTheEnvironment)
                in
                expectEquivalentTypeChecking modul
        ]



-- ============================================================================
-- CALLING KERNEL FUNCTIONS
-- ============================================================================


kernelCallingTests : Test
kernelCallingTests =
    Test.describe "Calling kernel functions"
        [ Test.test "Calling kernel-backed function with arguments types check equivalently" <|
            \_ ->
                let
                    -- batch : List a -> List a
                    -- batch = Elm.Kernel.List.batch
                    batchDef =
                        makeTypedDef "batch"
                            []
                            (varKernelExpr 2 "List" "batch")
                            (funType (listType (varType "a")) (listType (varType "a")))

                    -- testValue = batch [1, 2, 3]
                    testValueDef =
                        makeDef "testValue"
                            []
                            (callExpr 4
                                (varLocalExpr 5 "batch")
                                [ listExpr 6 [ intExpr 7 1, intExpr 8 2, intExpr 9 3 ] ]
                            )

                    modul =
                        makeModuleWithDecls
                            (Can.Declare batchDef
                                (Can.Declare testValueDef Can.SaveTheEnvironment)
                            )
                in
                expectEquivalentTypeChecking modul
        , Test.test "Calling kernel with empty list types check equivalently" <|
            \_ ->
                let
                    -- batch : List a -> List a
                    -- batch = Elm.Kernel.List.batch
                    batchDef =
                        makeTypedDef "batch"
                            []
                            (varKernelExpr 2 "List" "batch")
                            (funType (listType (varType "a")) (listType (varType "a")))

                    -- testValue = batch []
                    testValueDef =
                        makeDef "testValue"
                            []
                            (callExpr 4 (varLocalExpr 5 "batch") [ listExpr 6 [] ])

                    modul =
                        makeModuleWithDecls
                            (Can.Declare batchDef
                                (Can.Declare testValueDef Can.SaveTheEnvironment)
                            )
                in
                expectEquivalentTypeChecking modul
        , Test.fuzz (Fuzz.list Fuzz.int) "Calling kernel with fuzzed list types check equivalently" <|
            \nums ->
                let
                    batchDef =
                        makeTypedDef "batch"
                            []
                            (varKernelExpr 2 "List" "batch")
                            (funType (listType (varType "a")) (listType (varType "a")))

                    -- Build list expression from fuzzed ints
                    listItems =
                        List.indexedMap (\i n -> intExpr (10 + i) n) nums

                    testValueDef =
                        makeDef "testValue"
                            []
                            (callExpr 4 (varLocalExpr 5 "batch") [ listExpr 6 listItems ])

                    modul =
                        makeModuleWithDecls
                            (Can.Declare batchDef
                                (Can.Declare testValueDef Can.SaveTheEnvironment)
                            )
                in
                expectEquivalentTypeChecking modul
        ]



-- ============================================================================
-- WRAPPER FUNCTIONS CALLING KERNEL
-- ============================================================================


kernelWrapperTests : Test
kernelWrapperTests =
    Test.describe "Wrapper functions calling kernel"
        [ Test.test "Wrapper calling kernel-backed function types check equivalently (Platform/Cmd pattern)" <|
            \_ ->
                let
                    -- batch : List a -> a
                    -- batch = Elm.Kernel.X.batch
                    batchDef =
                        makeTypedDef "batch"
                            []
                            (varKernelExpr 2 "X" "batch")
                            (funType (listType (varType "a")) (varType "a"))

                    -- none = batch []
                    noneDef =
                        makeDef "none"
                            []
                            (callExpr 4 (varLocalExpr 5 "batch") [ listExpr 6 [] ])

                    modul =
                        makeModuleWithDecls
                            (Can.Declare batchDef
                                (Can.Declare noneDef Can.SaveTheEnvironment)
                            )
                in
                expectEquivalentTypeChecking modul
        , Test.test "Two kernel functions used together types check equivalently" <|
            \_ ->
                let
                    -- batch : List a -> List a
                    -- batch = Elm.Kernel.X.batch
                    batchDef =
                        makeTypedDef "batch"
                            []
                            (varKernelExpr 2 "X" "batch")
                            (funType (listType (varType "a")) (listType (varType "a")))

                    -- map : (a -> b) -> List a -> List b
                    -- map = Elm.Kernel.X.map
                    mapDef =
                        makeTypedDef "map"
                            []
                            (varKernelExpr 3 "X" "map")
                            (funType
                                (funType (varType "a") (varType "b"))
                                (funType (listType (varType "a")) (listType (varType "b")))
                            )

                    -- identity function: \x -> x
                    identityFn =
                        lambdaExpr 10 [ pVar 11 "x" ] (varLocalExpr 12 "x")

                    -- testValue = map identity (batch [])
                    testValueDef =
                        makeDef "testValue"
                            []
                            (callExpr 4
                                (callExpr 5 (varLocalExpr 6 "map") [ identityFn ])
                                [ callExpr 7 (varLocalExpr 8 "batch") [ listExpr 9 [] ] ]
                            )

                    modul =
                        makeModuleWithDecls
                            (Can.Declare batchDef
                                (Can.Declare mapDef
                                    (Can.Declare testValueDef Can.SaveTheEnvironment)
                                )
                            )
                in
                expectEquivalentTypeChecking modul
        , Test.test "Kernel in let expression types check equivalently" <|
            \_ ->
                let
                    -- testValue = let batch = Elm.Kernel.X.batch in batch []
                    batchLetDef =
                        makeTypedDef "batch"
                            []
                            (varKernelExpr 3 "X" "batch")
                            (funType (listType (varType "a")) (listType (varType "a")))

                    body =
                        callExpr 4 (varLocalExpr 5 "batch") [ listExpr 6 [] ]

                    expr =
                        letExpr 1 batchLetDef body

                    modul =
                        makeModule "testValue" expr
                in
                expectEquivalentTypeChecking modul
        ]



-- ============================================================================
-- KERNEL FUNCTIONS IN HIGHER-ORDER CONTEXTS
-- ============================================================================


kernelHigherOrderTests : Test
kernelHigherOrderTests =
    Test.describe "Kernel functions in higher-order contexts"
        [ Test.test "Kernel function passed to higher-order function types check equivalently" <|
            \_ ->
                let
                    -- apply : (a -> b) -> a -> b
                    -- apply f x = f x
                    applyDef =
                        makeDef "apply"
                            [ pVar 3 "f", pVar 4 "x" ]
                            (callExpr 5 (varLocalExpr 6 "f") [ varLocalExpr 7 "x" ])

                    -- batch : List a -> List a
                    -- batch = Elm.Kernel.X.batch
                    batchDef =
                        makeTypedDef "batch"
                            []
                            (varKernelExpr 9 "X" "batch")
                            (funType (listType (varType "a")) (listType (varType "a")))

                    -- testValue = apply batch [1]
                    testValueDef =
                        makeDef "testValue"
                            []
                            (callExpr 10
                                (varLocalExpr 11 "apply")
                                [ varLocalExpr 12 "batch"
                                , listExpr 13 [ intExpr 14 1 ]
                                ]
                            )

                    modul =
                        makeModuleWithDecls
                            (Can.Declare applyDef
                                (Can.Declare batchDef
                                    (Can.Declare testValueDef Can.SaveTheEnvironment)
                                )
                            )
                in
                expectEquivalentTypeChecking modul
        , Test.test "Kernel function used in composition types check equivalently" <|
            \_ ->
                let
                    -- compose : (b -> c) -> (a -> b) -> a -> c
                    -- compose f g x = f (g x)
                    composeDef =
                        makeDef "compose"
                            [ pVar 3 "f", pVar 4 "g", pVar 5 "x" ]
                            (callExpr 6
                                (varLocalExpr 7 "f")
                                [ callExpr 8 (varLocalExpr 9 "g") [ varLocalExpr 10 "x" ] ]
                            )

                    -- batch : List a -> List a
                    -- batch = Elm.Kernel.X.batch
                    batchDef =
                        makeTypedDef "batch"
                            []
                            (varKernelExpr 12 "X" "batch")
                            (funType (listType (varType "a")) (listType (varType "a")))

                    -- testValue = compose batch batch [1, 2]
                    testValueDef =
                        makeDef "testValue"
                            []
                            (callExpr 13
                                (varLocalExpr 14 "compose")
                                [ varLocalExpr 15 "batch"
                                , varLocalExpr 16 "batch"
                                , listExpr 17 [ intExpr 18 1, intExpr 19 2 ]
                                ]
                            )

                    modul =
                        makeModuleWithDecls
                            (Can.Declare composeDef
                                (Can.Declare batchDef
                                    (Can.Declare testValueDef Can.SaveTheEnvironment)
                                )
                            )
                in
                expectEquivalentTypeChecking modul
        ]



-- ============================================================================
-- VARKERNEL EXPRESSIONS (from Canonicalize tests)
-- These test VarKernel AST nodes directly with type annotations
-- ============================================================================


varKernelExprTests : Test
varKernelExprTests =
    Test.describe "VarKernel expressions"
        [ Test.test "VarKernel List.batch types check equivalently" <|
            \_ ->
                let
                    def =
                        makeTypedDef "testValue"
                            []
                            (varKernelExpr 1 "List" "batch")
                            (funType (listType (varType "a")) (listType (varType "a")))

                    modul =
                        makeModuleWithDecls (Can.Declare def Can.SaveTheEnvironment)
                in
                expectEquivalentTypeChecking modul
        , Test.test "VarKernel Platform.batch types check equivalently" <|
            \_ ->
                let
                    def =
                        makeTypedDef "testValue"
                            []
                            (varKernelExpr 1 "Platform" "batch")
                            (funType (listType (varType "a")) (varType "a"))

                    modul =
                        makeModuleWithDecls (Can.Declare def Can.SaveTheEnvironment)
                in
                expectEquivalentTypeChecking modul
        , Test.test "VarKernel Scheduler.succeed types check equivalently" <|
            \_ ->
                let
                    def =
                        makeTypedDef "testValue"
                            []
                            (varKernelExpr 1 "Scheduler" "succeed")
                            (funType (varType "a") (varType "a"))

                    modul =
                        makeModuleWithDecls (Can.Declare def Can.SaveTheEnvironment)
                in
                expectEquivalentTypeChecking modul
        , Test.test "VarKernel Process.spawn types check equivalently" <|
            \_ ->
                let
                    def =
                        makeTypedDef "testValue"
                            []
                            (varKernelExpr 1 "Process" "spawn")
                            (funType (varType "a") (varType "b"))

                    modul =
                        makeModuleWithDecls (Can.Declare def Can.SaveTheEnvironment)
                in
                expectEquivalentTypeChecking modul
        , Test.test "VarKernel JsArray.empty types check equivalently" <|
            \_ ->
                let
                    def =
                        makeTypedDef "testValue"
                            []
                            (varKernelExpr 1 "JsArray" "empty")
                            (listType (varType "a"))

                    modul =
                        makeModuleWithDecls (Can.Declare def Can.SaveTheEnvironment)
                in
                expectEquivalentTypeChecking modul
        , Test.test "VarKernel Utils.Tuple2 types check equivalently" <|
            \_ ->
                let
                    def =
                        makeTypedDef "testValue"
                            []
                            (varKernelExpr 1 "Utils" "Tuple2")
                            (funType (varType "a") (funType (varType "b") (tupleType (varType "a") (varType "b") [])))

                    modul =
                        makeModuleWithDecls (Can.Declare def Can.SaveTheEnvironment)
                in
                expectEquivalentTypeChecking modul
        ]



-- ============================================================================
-- VARKERNEL FUNCTION CALLS
-- ============================================================================


varKernelCallTests : Test
varKernelCallTests =
    Test.describe "VarKernel function calls"
        [ Test.test "Calling VarKernel with int arg types check equivalently" <|
            \_ ->
                let
                    singletonDef =
                        makeTypedDef "singleton"
                            []
                            (varKernelExpr 1 "List" "singleton")
                            (funType (varType "a") (listType (varType "a")))

                    testDef =
                        makeDef "testValue"
                            []
                            (callExpr 3 (varLocalExpr 4 "singleton") [ intExpr 5 42 ])

                    modul =
                        makeModuleWithDecls
                            (Can.Declare singletonDef
                                (Can.Declare testDef Can.SaveTheEnvironment)
                            )
                in
                expectEquivalentTypeChecking modul
        , Test.test "Calling VarKernel with multiple args types check equivalently" <|
            \_ ->
                let
                    consDef =
                        makeTypedDef "cons"
                            []
                            (varKernelExpr 1 "List" "cons")
                            (funType (varType "a") (funType (listType (varType "a")) (listType (varType "a"))))

                    testDef =
                        makeDef "testValue"
                            []
                            (callExpr 3 (varLocalExpr 4 "cons") [ intExpr 5 1, listExpr 6 [] ])

                    modul =
                        makeModuleWithDecls
                            (Can.Declare consDef
                                (Can.Declare testDef Can.SaveTheEnvironment)
                            )
                in
                expectEquivalentTypeChecking modul
        , Test.test "Nested VarKernel calls types check equivalently" <|
            \_ ->
                let
                    singletonDef =
                        makeTypedDef "singleton"
                            []
                            (varKernelExpr 1 "List" "singleton")
                            (funType (varType "a") (listType (varType "a")))

                    headDef =
                        makeTypedDef "head"
                            []
                            (varKernelExpr 2 "List" "head")
                            (funType (listType (varType "a")) (varType "a"))

                    innerCall =
                        callExpr 4 (varLocalExpr 5 "singleton") [ intExpr 6 1 ]

                    testDef =
                        makeDef "testValue"
                            []
                            (callExpr 7 (varLocalExpr 8 "head") [ innerCall ])

                    modul =
                        makeModuleWithDecls
                            (Can.Declare singletonDef
                                (Can.Declare headDef
                                    (Can.Declare testDef Can.SaveTheEnvironment)
                                )
                            )
                in
                expectEquivalentTypeChecking modul
        , Test.test "Multiple VarKernel calls in tuple types check equivalently" <|
            \_ ->
                let
                    headDef =
                        makeTypedDef "head"
                            []
                            (varKernelExpr 1 "List" "head")
                            (funType (listType (varType "a")) (varType "a"))

                    tailDef =
                        makeTypedDef "tail"
                            []
                            (varKernelExpr 2 "List" "tail")
                            (funType (listType (varType "a")) (listType (varType "a")))

                    call1 =
                        callExpr 4 (varLocalExpr 5 "head") [ listExpr 6 [ intExpr 7 1 ] ]

                    call2 =
                        callExpr 8 (varLocalExpr 9 "tail") [ listExpr 10 [ intExpr 11 2 ] ]

                    testDef =
                        makeDef "testValue"
                            []
                            (tupleExpr 12 call1 call2)

                    modul =
                        makeModuleWithDecls
                            (Can.Declare headDef
                                (Can.Declare tailDef
                                    (Can.Declare testDef Can.SaveTheEnvironment)
                                )
                            )
                in
                expectEquivalentTypeChecking modul
        , Test.test "VarKernel as higher-order argument types check equivalently" <|
            \_ ->
                let
                    applyDef =
                        makeDef "apply"
                            [ pVar 2 "f", pVar 3 "x" ]
                            (callExpr 4 (varLocalExpr 5 "f") [ varLocalExpr 6 "x" ])

                    singletonDef =
                        makeTypedDef "singleton"
                            []
                            (varKernelExpr 7 "List" "singleton")
                            (funType (varType "a") (listType (varType "a")))

                    testDef =
                        makeDef "testValue"
                            []
                            (callExpr 9 (varLocalExpr 10 "apply") [ varLocalExpr 11 "singleton", intExpr 12 42 ])

                    modul =
                        makeModuleWithDecls
                            (Can.Declare applyDef
                                (Can.Declare singletonDef
                                    (Can.Declare testDef Can.SaveTheEnvironment)
                                )
                            )
                in
                expectEquivalentTypeChecking modul
        , Test.test "VarKernel functions in list types check equivalently" <|
            \_ ->
                let
                    headDef =
                        makeTypedDef "head"
                            []
                            (varKernelExpr 1 "List" "head")
                            (funType (listType intType) intType)

                    tailDef =
                        makeTypedDef "tail"
                            []
                            (varKernelExpr 2 "List" "tail")
                            (funType (listType intType) (listType intType))

                    lengthDef =
                        makeTypedDef "length"
                            []
                            (varKernelExpr 3 "List" "length")
                            (funType (listType intType) intType)

                    testDef =
                        makeDef "testValue"
                            []
                            (listExpr 5 [ varLocalExpr 6 "head", varLocalExpr 7 "length" ])

                    modul =
                        makeModuleWithDecls
                            (Can.Declare headDef
                                (Can.Declare tailDef
                                    (Can.Declare lengthDef
                                        (Can.Declare testDef Can.SaveTheEnvironment)
                                    )
                                )
                            )
                in
                expectEquivalentTypeChecking modul
        ]



-- ============================================================================
-- VARKERNEL IN CONTEXT
-- ============================================================================


varKernelContextTests : Test
varKernelContextTests =
    Test.describe "VarKernel in context"
        [ Test.test "VarKernel in lambda body types check equivalently" <|
            \_ ->
                let
                    singletonDef =
                        makeTypedDef "singleton"
                            []
                            (varKernelExpr 1 "List" "singleton")
                            (funType (varType "a") (listType (varType "a")))

                    body =
                        callExpr 3 (varLocalExpr 4 "singleton") [ varLocalExpr 5 "x" ]

                    lambda =
                        lambdaExpr 6 [ pVar 7 "x" ] body

                    testDef =
                        makeDef "testValue"
                            []
                            lambda

                    modul =
                        makeModuleWithDecls
                            (Can.Declare singletonDef
                                (Can.Declare testDef Can.SaveTheEnvironment)
                            )
                in
                expectEquivalentTypeChecking modul
        , Test.test "VarKernel in let binding types check equivalently" <|
            \_ ->
                let
                    singletonDef =
                        makeTypedDef "singleton"
                            []
                            (varKernelExpr 1 "List" "singleton")
                            (funType (varType "a") (listType (varType "a")))

                    innerDef =
                        makeDef "result" [] (callExpr 3 (varLocalExpr 4 "singleton") [ intExpr 5 1 ])

                    expr =
                        letExpr 6 innerDef (varLocalExpr 7 "result")

                    testDef =
                        makeDef "testValue"
                            []
                            expr

                    modul =
                        makeModuleWithDecls
                            (Can.Declare singletonDef
                                (Can.Declare testDef Can.SaveTheEnvironment)
                            )
                in
                expectEquivalentTypeChecking modul
        , Test.test "Multiple VarKernel from same module types check equivalently" <|
            \_ ->
                let
                    consDef =
                        makeTypedDef "cons"
                            []
                            (varKernelExpr 1 "List" "cons")
                            (funType (varType "a") (funType (listType (varType "a")) (listType (varType "a"))))

                    singletonDef =
                        makeTypedDef "singleton"
                            []
                            (varKernelExpr 2 "List" "singleton")
                            (funType (varType "a") (listType (varType "a")))

                    appendDef =
                        makeTypedDef "append"
                            []
                            (varKernelExpr 3 "List" "append")
                            (funType (listType (varType "a")) (funType (listType (varType "a")) (listType (varType "a"))))

                    testDef =
                        makeDef "testValue"
                            []
                            (listExpr 5 [ intExpr 6 1, intExpr 7 2, intExpr 8 3 ])

                    modul =
                        makeModuleWithDecls
                            (Can.Declare consDef
                                (Can.Declare singletonDef
                                    (Can.Declare appendDef
                                        (Can.Declare testDef Can.SaveTheEnvironment)
                                    )
                                )
                            )
                in
                expectEquivalentTypeChecking modul
        , Test.test "VarKernel from different modules types check equivalently" <|
            \_ ->
                let
                    consDef =
                        makeTypedDef "cons"
                            []
                            (varKernelExpr 1 "List" "cons")
                            (funType (varType "a") (funType (listType (varType "a")) (listType (varType "a"))))

                    batchDef =
                        makeTypedDef "batch"
                            []
                            (varKernelExpr 2 "Platform" "batch")
                            (funType (listType (varType "a")) (varType "a"))

                    succeedDef =
                        makeTypedDef "succeed"
                            []
                            (varKernelExpr 3 "Scheduler" "succeed")
                            (funType (varType "a") (varType "a"))

                    testDef =
                        makeDef "testValue"
                            []
                            (intExpr 5 42)

                    modul =
                        makeModuleWithDecls
                            (Can.Declare consDef
                                (Can.Declare batchDef
                                    (Can.Declare succeedDef
                                        (Can.Declare testDef Can.SaveTheEnvironment)
                                    )
                                )
                            )
                in
                expectEquivalentTypeChecking modul
        , Test.test "VarKernel with complex args types check equivalently" <|
            \_ ->
                let
                    pairDef =
                        makeTypedDef "pair"
                            []
                            (varKernelExpr 1 "Utils" "pair")
                            (funType (varType "a") (funType (varType "b") (tupleType (varType "a") (varType "b") [])))

                    arg1 =
                        tupleExpr 3 (intExpr 4 1) (intExpr 5 2)

                    arg2 =
                        listExpr 6 [ intExpr 7 3, intExpr 8 4 ]

                    testDef =
                        makeDef "testValue"
                            []
                            (callExpr 9 (varLocalExpr 10 "pair") [ arg1, arg2 ])

                    modul =
                        makeModuleWithDecls
                            (Can.Declare pairDef
                                (Can.Declare testDef Can.SaveTheEnvironment)
                            )
                in
                expectEquivalentTypeChecking modul
        , Test.test "Chained VarKernel calls types check equivalently" <|
            \_ ->
                let
                    singletonDef =
                        makeTypedDef "singleton"
                            []
                            (varKernelExpr 1 "List" "singleton")
                            (funType (varType "a") (listType (varType "a")))

                    tailDef =
                        makeTypedDef "tail"
                            []
                            (varKernelExpr 2 "List" "tail")
                            (funType (listType (varType "a")) (listType (varType "a")))

                    headDef =
                        makeTypedDef "head"
                            []
                            (varKernelExpr 3 "List" "head")
                            (funType (listType (varType "a")) (varType "a"))

                    -- head (tail (singleton 1))
                    innermost =
                        callExpr 5 (varLocalExpr 6 "singleton") [ intExpr 7 1 ]

                    middle =
                        callExpr 8 (varLocalExpr 9 "tail") [ innermost ]

                    outer =
                        callExpr 10 (varLocalExpr 11 "head") [ middle ]

                    testDef =
                        makeDef "testValue"
                            []
                            outer

                    modul =
                        makeModuleWithDecls
                            (Can.Declare singletonDef
                                (Can.Declare tailDef
                                    (Can.Declare headDef
                                        (Can.Declare testDef Can.SaveTheEnvironment)
                                    )
                                )
                            )
                in
                expectEquivalentTypeChecking modul
        ]



-- ============================================================================
-- VARKERNEL FUZZ TESTS
-- ============================================================================


varKernelFuzzTests : Test
varKernelFuzzTests =
    Test.describe "VarKernel fuzz tests"
        [ Test.fuzz Fuzz.int "VarKernel call with fuzzed int types check equivalently" <|
            \n ->
                let
                    singletonDef =
                        makeTypedDef "singleton"
                            []
                            (varKernelExpr 1 "List" "singleton")
                            (funType (varType "a") (listType (varType "a")))

                    testDef =
                        makeDef "testValue"
                            []
                            (callExpr 3 (varLocalExpr 4 "singleton") [ intExpr 5 n ])

                    modul =
                        makeModuleWithDecls
                            (Can.Declare singletonDef
                                (Can.Declare testDef Can.SaveTheEnvironment)
                            )
                in
                expectEquivalentTypeChecking modul
        , Test.fuzz3 Fuzz.int Fuzz.int Fuzz.int "Multiple VarKernel calls with fuzzed ints types check equivalently" <|
            \a b c ->
                let
                    singletonDef =
                        makeTypedDef "singleton"
                            []
                            (varKernelExpr 1 "List" "singleton")
                            (funType (varType "a") (listType (varType "a")))

                    call1 =
                        callExpr 3 (varLocalExpr 4 "singleton") [ intExpr 5 a ]

                    call2 =
                        callExpr 6 (varLocalExpr 7 "singleton") [ intExpr 8 b ]

                    call3 =
                        callExpr 9 (varLocalExpr 10 "singleton") [ intExpr 11 c ]

                    testDef =
                        makeDef "testValue"
                            []
                            (listExpr 12 [ call1, call2, call3 ])

                    modul =
                        makeModuleWithDecls
                            (Can.Declare singletonDef
                                (Can.Declare testDef Can.SaveTheEnvironment)
                            )
                in
                expectEquivalentTypeChecking modul
        ]
