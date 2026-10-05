module TestLogic.Type.PostSolve.KernelTypesTest exposing (suite)

{-| Runs the kernel type environment check on three programs that call kernel
functions (POST\_002).

The kernel type environment is the table, keyed by home module and function
name, that PostSolve builds and typed optimization reads the types of kernel
functions from (`Compiler.Type.KernelTypes`). The check,
`TestLogic.Type.PostSolve.KernelTypes.expectKernelTypesValid`, requires every
directly called kernel to have an entry, equal to the kernel reference's node
type after PostSolve.

The programs are built with `Compiler.AST.SourceBuilder` as modules of the
kernel package the test pipeline compiles as, so kernel references are
accepted:

  - `useFromArray : List String -> List String`, which returns
    `Elm.Kernel.List.fromArray` applied to its argument.
  - `sumBoth n = Elm.Kernel.Basics.add n n` and `y = sumBoth 1`, unannotated,
    so the kernel's entry comes from types the solver inferred.
  - two calls of `Elm.Kernel.List.fromArray` at different element types,
    `[ 1 ]` and `[ "a" ]`: the first usage wins, so the second kernel
    reference must still carry the first usage's entry.

Among what is not tested: kernel references that are not called, kernel
aliases, and whether an entry agrees with the kernel's real type.

-}

import Compiler.AST.SourceBuilder as SB
import Test exposing (Test)
import TestLogic.Type.PostSolve.KernelTypes exposing (expectKernelTypesValid)


{-| The kernel type environment tests, grouped under one label.
-}
suite : Test
suite =
    Test.describe "Kernel types are correctly resolved (POST_002)"
        [ kernelTypeTests
        ]


{-| The three kernel programs, each run through `expectKernelTypesValid`.
-}
kernelTypeTests : Test
kernelTypeTests =
    Test.describe "Kernel type resolution"
        [ Test.test "annotated kernel call has its entry" <|
            \_ ->
                SB.makeModuleWithTypedDefs "AnnotatedKernel"
                    [ { name = "useFromArray"
                      , args = [ SB.pVar "x" ]
                      , tipe =
                            SB.tLambda (SB.tType "List" [ SB.tType "String" [] ])
                                (SB.tType "List" [ SB.tType "String" [] ])
                      , body = SB.callExpr (SB.qualVarExpr "Elm.Kernel.List" "fromArray") [ SB.varExpr "x" ]
                      }
                    ]
                    |> expectKernelTypesValid
        , Test.test "inferred kernel call has its entry" <|
            \_ ->
                SB.makeModuleWithDefs "InferredKernel"
                    [ ( "sumBoth"
                      , [ SB.pVar "n" ]
                      , SB.callExpr (SB.qualVarExpr "Elm.Kernel.Basics" "add") [ SB.varExpr "n", SB.varExpr "n" ]
                      )
                    , ( "y", [], SB.callExpr (SB.varExpr "sumBoth") [ SB.intExpr 1 ] )
                    ]
                    |> expectKernelTypesValid
        , Test.test "the first usage of a kernel gives every reference its entry" <|
            \_ ->
                SB.makeModuleWithDefs "TwoUsages"
                    [ ( "ints", [], SB.callExpr (SB.qualVarExpr "Elm.Kernel.List" "fromArray") [ SB.listExpr [ SB.intExpr 1 ] ] )
                    , ( "strs", [], SB.callExpr (SB.qualVarExpr "Elm.Kernel.List" "fromArray") [ SB.listExpr [ SB.strExpr "a" ] ] )
                    ]
                    |> expectKernelTypesValid
        ]
