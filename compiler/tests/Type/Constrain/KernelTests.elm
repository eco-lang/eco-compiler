module Type.Constrain.KernelTests exposing (suite)

{-| Tests that the compiler's two type-checking paths agree on modules that use
kernel references. The erased path yields only a module's top-level
annotations; the typed path also records a _node type_, the solved type of an
expression, keyed by the expression's id. `Type.Constrain.Shared` describes
both.

A _kernel reference_ (`Can.VarKernel`) names a value of a kernel module, such as
`Elm.Kernel.List.cons`, whose implementation is not Elm source. The constraint
generator looks a kernel reference up in `Compiler.Type.KernelIntrinsics`, and
one with no row there contributes no constraint of its own, so its type is
bounded only by what surrounds it. None of the kernels named here has a row,
so every test exercises that unconstrained case, and a name such as
`Elm.Kernel.X.batch` serves as well as a real one.

The fixture is one canonical module per test, built by hand with
`Compiler.AST.CanonicalBuilder`. In every module each kernel reference is the
whole body of an annotated definition, such as `batch : List a -> List a` bound
to `Elm.Kernel.List.batch`; in most, other definitions then use it. Those uses
are built as local variables (`varLocalExpr`) rather than top-level references,
which the constraint generator treats alike. Expression and pattern ids are
written by hand, and no two nodes in one module share an id.

Each test's only assertion is
`Type.Constrain.Shared.expectEquivalentTypeChecking`. It passes when both paths
reject the module; otherwise it requires both to accept it, and the typed path
to give a node type to each expression id. The tests, group by group:

  - `simpleKernelTests`: a lone annotated definition bound to a kernel, at four
    types.
  - `kernelCallingTests`: a kernel-bound `batch` called on a list of three
    `Int`s, on the empty list, and on a fuzzed list of `Int`s.
  - `kernelWrapperTests`: a definition that calls a kernel-bound one, two
    kernel-bound definitions combined in one expression, and a kernel bound in
    a `let`.
  - `kernelHigherOrderTests`: a kernel-bound definition passed to unannotated
    `apply` and `compose` functions.
  - `varKernelExprTests`: a lone annotated definition bound to a kernel, for a
    kernel of each of six kernel modules.
  - `varKernelCallTests`: kernel-bound `List` definitions called with one and
    two arguments, nested, side by side in a pair, passed to `apply`, and placed
    unapplied in a list.
  - `varKernelContextTests`: kernel-bound definitions called inside a lambda, a
    `let` and a chain of calls, and with a tuple and a list as arguments, plus
    two modules whose `testValue` uses none of the kernel-bound definitions
    beside it.
  - `varKernelFuzzTests`: `singleton` called on one fuzzed `Int`, and three
    calls of `singleton`, each on a fuzzed `Int`, collected in a list.

Among what is not tested: that any of these modules type-checks, since a module
both paths reject passes; the annotations either path infers; a kernel with a
row in `Compiler.Type.KernelIntrinsics`; a kernel reference under the `Eco`
prefix, which `varKernelExpr` cannot build; and a kernel reference anywhere but
as the whole body of an annotated definition.

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


{-| Every group of kernel type-checking tests in this module, under one
`describe`.
-}
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


{-| The tests of a module whose one definition is annotated and bound to a
kernel: `Elm.Kernel.List.batch` as `List a -> List a`, `Elm.Kernel.Time.now` as
`Int`, `Elm.Kernel.List.map` as `(a -> b) -> List a -> List b`, and
`Elm.Kernel.Tuple.pair` as `a -> b -> ( a, b )`.
-}
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


{-| The tests of `batch`, annotated `List a -> List a` and bound to
`Elm.Kernel.List.batch`, called from an unannotated `testValue`: on
`[ 1, 2, 3 ]`, on `[]`, and on a list of fuzzed `Int`s, which may be empty.
-}
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


{-| The tests of definitions that use kernel-bound ones, with kernels of the
module `Elm.Kernel.X`.

The first declares `batch : List a -> a` and the unannotated `none = batch []`.
The second declares `batch : List a -> List a` and
`map : (a -> b) -> List a -> List b`, and uses both in
`testValue = map (\x -> x) (batch [])`. The third is a module whose one
definition, `testValue`, is a `let` binding an annotated `batch` to the kernel,
with body `batch []`.

-}
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
                    -- testValue = let batch : List a -> List a; batch = Elm.Kernel.X.batch in batch []
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


{-| The tests of `batch`, annotated `List a -> List a` and bound to
`Elm.Kernel.X.batch`, passed as an argument to an unannotated function:
`apply batch [ 1 ]` with `apply f x = f x`, and `compose batch batch [ 1, 2 ]`
with `compose f g x = f (g x)`.
-}
kernelHigherOrderTests : Test
kernelHigherOrderTests =
    Test.describe "Kernel functions in higher-order contexts"
        [ Test.test "Kernel function passed to higher-order function types check equivalently" <|
            \_ ->
                let
                    -- apply f x = f x, with no annotation
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
                    -- compose f g x = f (g x), with no annotation
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
-- VARKERNEL EXPRESSIONS
-- ============================================================================


{-| The tests of a module whose one definition, `testValue`, is annotated and
bound to a kernel: `Elm.Kernel.List.batch` as `List a -> List a`,
`Elm.Kernel.Platform.batch` as `List a -> a`, `Elm.Kernel.Scheduler.succeed` as
`a -> a`, `Elm.Kernel.Process.spawn` as `a -> b`, `Elm.Kernel.JsArray.empty` as
`List a`, and `Elm.Kernel.Utils.Tuple2` as `a -> b -> ( a, b )`.
-}
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


{-| The tests of definitions bound to `Elm.Kernel.List` kernels and used by an
unannotated `testValue`.

The uses are `singleton 42`, `cons 1 []`, `head (singleton 1)`, the pair
`( head [ 1 ], tail [ 2 ] )`, and `apply singleton 42` with an unannotated
`apply f x = f x`. These annotate the kernels polymorphically, `head` as
`List a -> a`. The last test annotates `head`, `tail` and `length` at `Int`
and makes `testValue` the list `[ head, length ]` of the two unapplied
functions of type `List Int -> Int`; `tail` is declared and not used.

-}
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


{-| The tests of kernel-bound definitions used inside other expressions, alone
and several together.

The uses are `\x -> singleton x`, `let result = singleton 1 in result`,
`pair ( 1, 2 ) [ 3, 4 ]` with `pair` bound to `Elm.Kernel.Utils.pair` as
`a -> b -> ( a, b )`, and `head (tail (singleton 1))`; the other kernels in
these four tests are from `Elm.Kernel.List`. Two tests use several kernel-bound
definitions together: `testValue = append (singleton 1) (cons 2 [ 3 ])` with
`cons`, `singleton` and `append` from `Elm.Kernel.List`, and
`testValue = ( cons 1 [ 2 ], batch [ succeed 42 ] )` with kernels from
`Elm.Kernel.List`, `Elm.Kernel.Platform` and `Elm.Kernel.Scheduler`.

-}
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

                    -- append (singleton 1) (cons 2 [ 3 ])
                    testDef =
                        makeDef "testValue"
                            []
                            (callExpr 5
                                (varLocalExpr 6 "append")
                                [ callExpr 7 (varLocalExpr 8 "singleton") [ intExpr 9 1 ]
                                , callExpr 10 (varLocalExpr 11 "cons") [ intExpr 12 2, listExpr 13 [ intExpr 14 3 ] ]
                                ]
                            )

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

                    -- ( cons 1 [ 2 ], batch [ succeed 42 ] )
                    testDef =
                        makeDef "testValue"
                            []
                            (tupleExpr 5
                                (callExpr 6 (varLocalExpr 7 "cons") [ intExpr 8 1, listExpr 9 [ intExpr 10 2 ] ])
                                (callExpr 11
                                    (varLocalExpr 12 "batch")
                                    [ listExpr 13 [ callExpr 14 (varLocalExpr 15 "succeed") [ intExpr 16 42 ] ] ]
                                )
                            )

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


{-| The fuzz tests of `singleton`, annotated `a -> List a` and bound to
`Elm.Kernel.List.singleton`: `singleton n` for one fuzzed `Int`, and the list
of `singleton` applied to each of three fuzzed `Int`s. The fuzzed values reach
only `Int` literals, so they cannot change the module's types.
-}
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
