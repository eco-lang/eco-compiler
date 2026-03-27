module Compiler.Data.NameKernelTest exposing (suite)

{-| Tests for kernel name prefix detection and stripping.

Verifies that getKernel correctly distinguishes Elm.Kernel.* from
Eco.Kernel.* prefixes, which is critical for MLIR codegen to emit
the correct C function name prefix (Elm_Kernel_ vs Eco_Kernel_).

-}

import Compiler.Data.Name as Name
import Expect
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Name.getKernel"
        [ Test.test "Elm.Kernel.List returns (Elm, List)" <|
            \_ ->
                Name.getKernel "Elm.Kernel.List"
                    |> Expect.equal ( "Elm", "List" )
        , Test.test "Eco.Kernel.File returns (Eco, File)" <|
            \_ ->
                Name.getKernel "Eco.Kernel.File"
                    |> Expect.equal ( "Eco", "File" )
        , Test.test "Elm.Kernel.File and Eco.Kernel.File are distinguishable" <|
            \_ ->
                let
                    elm =
                        Name.getKernel "Elm.Kernel.File"

                    eco =
                        Name.getKernel "Eco.Kernel.File"
                in
                Expect.notEqual elm eco
        , Test.test "Elm.Kernel.Http returns (Elm, Http)" <|
            \_ ->
                Name.getKernel "Elm.Kernel.Http"
                    |> Expect.equal ( "Elm", "Http" )
        , Test.test "Eco.Kernel.Http returns (Eco, Http)" <|
            \_ ->
                Name.getKernel "Eco.Kernel.Http"
                    |> Expect.equal ( "Eco", "Http" )
        , Test.test "Eco.Kernel.Crash returns (Eco, Crash)" <|
            \_ ->
                Name.getKernel "Eco.Kernel.Crash"
                    |> Expect.equal ( "Eco", "Crash" )
        ]
