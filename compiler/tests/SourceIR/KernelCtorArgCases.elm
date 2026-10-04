module SourceIR.KernelCtorArgCases exposing (expectSuite)

{-| Programs that put the results of kernel calls inside tuples, lists and
custom-type values, or pass a value built from tuples to the kernel reference
`Elm.Kernel.Basics.identity`, so that a compiler stage can be checked on kernel
calls combined with data structures.

A kernel function is one the runtime implements rather than Elm code, written
as a qualified reference such as `Elm.Kernel.Basics.add`. When a module of a
kernel package is canonicalized, such a reference becomes a direct kernel
reference (`Can.VarKernel`). None of the kernels used here has a declared type
for the type checker, so the type of each call comes only from the code around
it, and `Compiler.Type.PostSolve` records a type for each kernel after solving.
In the two custom-type programs the definition is annotated, so the
constructor's type fixes what each kernel call must return. In the others no
annotation states the result type of any kernel call.

This module asserts nothing. `expectSuite` gives the programs, in order, to
the expectation function its caller supplies, stopping at the first one that
function rejects, and that function decides what is checked. The programs run
as one test through `Compiler.BulkCheck.bulkCheck`, so a failure names only the
first program that fails.

Every program is a module named `Test` whose one value is `testValue`, with no
arguments. Five are built with `makeKernelModule`, which leaves `testValue`
unannotated. The two custom-type programs are built with
`makeModuleWithTypedDefsUnionsAliases`, which annotates `testValue` and
declares the type. In the list below, `add`, `sub` and `mul` are the
`Elm.Kernel.Basics` kernels of those names, and `identity` stands for the
reference `Elm.Kernel.Basics.identity`, which canonicalization accepts without
checking the name although no runtime implements it.

  - "Tuple with kernel result": `testValue` is `( add 1 2, mul 3 4 )`.
  - "List of kernel results": `testValue` is
    `[ add 1 2, sub 5 3, mul 2 2 ]`.
  - "Kernel result in let then ctor": `testValue : Wrapper Int` is
    `Wrap (add 10 20)`, with `type Wrapper a = Wrap a`. Despite the label, the
    program has no `let`.
  - "Custom ctor with kernel arg": `testValue : Pair Int String` is
    `MkPair (add 1 2) (Elm.Kernel.String.fromNumber 42)`, with
    `type Pair a b = MkPair a b`.
  - "Nested kernel in tuple": `testValue` is `( ( add 1 2, 3 ), mul 4 5 )`.
  - "Kernel identity on tuple": `testValue` is `identity ( 1, "hello" )`.
  - "Kernel identity on record-like tuple": `testValue` is
    `identity [ ( 1, 2 ), ( 3, 4 ) ]`. Despite the label, the program has no
    record.

Among what is not tested: a kernel function passed to a constructor without
being called, which `Compiler.Type.PostSolve` handles separately from a kernel
call's result, records, and kernel results inside `case` or `let` expressions.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( callExpr
        , ctorExpr
        , intExpr
        , listExpr
        , makeKernelModule
        , makeModuleWithTypedDefsUnionsAliases
        , qualVarExpr
        , strExpr
        , tType
        , tVar
        , tupleExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Returns one test, named "Kernel ctor args " followed by `condStr`, that
gives the programs in this module to `expectFn` in turn until one is rejected,
and then fails with that program's label.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Kernel ctor args " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns the seven programs as labelled cases, each giving its program to
`expectFn` when it is run.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "Tuple with kernel result", run = tupleWithKernel expectFn }
    , { label = "List of kernel results", run = listOfKernelResults expectFn }
    , { label = "Kernel result in let then ctor", run = kernelInLetThenCtor expectFn }
    , { label = "Custom ctor with kernel arg", run = customCtorWithKernel expectFn }
    , { label = "Nested kernel in tuple", run = nestedKernelTuple expectFn }
    , { label = "Kernel identity on tuple", run = kernelIdentityTuple expectFn }
    , { label = "Kernel identity on record-like tuple", run = kernelIdentityRecordTuple expectFn }
    ]


{-| Gives `expectFn` the program whose `testValue` is a pair of two kernel
call results, `Elm.Kernel.Basics.add 1 2` and `Elm.Kernel.Basics.mul 3 4`.
-}
tupleWithKernel : (Src.Module -> Expectation) -> (() -> Expectation)
tupleWithKernel expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (tupleExpr
                (callExpr (qualVarExpr "Elm.Kernel.Basics" "add") [ intExpr 1, intExpr 2 ])
                (callExpr (qualVarExpr "Elm.Kernel.Basics" "mul") [ intExpr 3, intExpr 4 ])
            )
        )


{-| Gives `expectFn` the program whose `testValue` is a list of three kernel
call results, from `Elm.Kernel.Basics.add`, `sub` and `mul`.
-}
listOfKernelResults : (Src.Module -> Expectation) -> (() -> Expectation)
listOfKernelResults expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (listExpr
                [ callExpr (qualVarExpr "Elm.Kernel.Basics" "add") [ intExpr 1, intExpr 2 ]
                , callExpr (qualVarExpr "Elm.Kernel.Basics" "sub") [ intExpr 5, intExpr 3 ]
                , callExpr (qualVarExpr "Elm.Kernel.Basics" "mul") [ intExpr 2, intExpr 2 ]
                ]
            )
        )


{-| Gives `expectFn` the program that declares `type Wrapper a = Wrap a` and
defines `testValue : Wrapper Int` as `Wrap` applied to
`Elm.Kernel.Basics.add 10 20`. The `let` is in this test code, not in the
program.
-}
kernelInLetThenCtor : (Src.Module -> Expectation) -> (() -> Expectation)
kernelInLetThenCtor expectFn _ =
    let
        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ { name = "testValue"
                  , args = []
                  , tipe = tType "Wrapper" [ tType "Int" [] ]
                  , body =
                        callExpr (ctorExpr "Wrap")
                            [ callExpr (qualVarExpr "Elm.Kernel.Basics" "add") [ intExpr 10, intExpr 20 ] ]
                  }
                ]
                [ { name = "Wrapper"
                  , args = [ "a" ]
                  , ctors = [ { name = "Wrap", args = [ tVar "a" ] } ]
                  }
                ]
                []
    in
    expectFn modul


{-| Gives `expectFn` the program that declares `type Pair a b = MkPair a b` and
defines `testValue : Pair Int String` as `MkPair` applied to
`Elm.Kernel.Basics.add 1 2` and `Elm.Kernel.String.fromNumber 42`.
-}
customCtorWithKernel : (Src.Module -> Expectation) -> (() -> Expectation)
customCtorWithKernel expectFn _ =
    let
        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ { name = "testValue"
                  , args = []
                  , tipe = tType "Pair" [ tType "Int" [], tType "String" [] ]
                  , body =
                        callExpr (ctorExpr "MkPair")
                            [ callExpr (qualVarExpr "Elm.Kernel.Basics" "add") [ intExpr 1, intExpr 2 ]
                            , callExpr (qualVarExpr "Elm.Kernel.String" "fromNumber") [ intExpr 42 ]
                            ]
                  }
                ]
                [ { name = "Pair"
                  , args = [ "a", "b" ]
                  , ctors = [ { name = "MkPair", args = [ tVar "a", tVar "b" ] } ]
                  }
                ]
                []
    in
    expectFn modul


{-| Gives `expectFn` the program whose `testValue` is a pair whose first
element is itself a pair holding the result of `Elm.Kernel.Basics.add 1 2`,
and whose second element is the result of `Elm.Kernel.Basics.mul 4 5`.
-}
nestedKernelTuple : (Src.Module -> Expectation) -> (() -> Expectation)
nestedKernelTuple expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (tupleExpr
                (tupleExpr (callExpr (qualVarExpr "Elm.Kernel.Basics" "add") [ intExpr 1, intExpr 2 ]) (intExpr 3))
                (callExpr (qualVarExpr "Elm.Kernel.Basics" "mul") [ intExpr 4, intExpr 5 ])
            )
        )


{-| Gives `expectFn` the program whose `testValue` is
`Elm.Kernel.Basics.identity` applied to the pair `( 1, "hello" )`.
-}
kernelIdentityTuple : (Src.Module -> Expectation) -> (() -> Expectation)
kernelIdentityTuple expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Elm.Kernel.Basics" "identity")
                [ tupleExpr (intExpr 1) (strExpr "hello") ]
            )
        )


{-| Gives `expectFn` the program whose `testValue` is
`Elm.Kernel.Basics.identity` applied to the list `[ ( 1, 2 ), ( 3, 4 ) ]`.
-}
kernelIdentityRecordTuple : (Src.Module -> Expectation) -> (() -> Expectation)
kernelIdentityRecordTuple expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Elm.Kernel.Basics" "identity")
                [ listExpr [ tupleExpr (intExpr 1) (intExpr 2), tupleExpr (intExpr 3) (intExpr 4) ] ]
            )
        )
