module Compiler.Data.NameKernelTest exposing (suite)

{-| Tests for `Name.getKernel`, which splits the name of a kernel module into its
kernel prefix and its home module.

A kernel module is one named `Elm.Kernel.X` or `Eco.Kernel.X`; its prefix is
`Elm` or `Eco` and its home is `X`. When the canonicalizer resolves a qualified
reference into a kernel module it keeps both halves, and MLIR code generation
names the kernel's C symbol starting `<prefix>_Kernel_<home>_`. A wrong split
would make a reference name a different kernel's symbol.

The fixture is nothing more than literal module names.

The tests establish:

  - `Elm.Kernel.List` and `Elm.Kernel.Http` split into `( "Elm", "List" )` and
    `( "Elm", "Http" )`.
  - `Eco.Kernel.File`, `Eco.Kernel.Http` and `Eco.Kernel.Crash` split into
    `( "Eco", "File" )`, `( "Eco", "Http" )` and `( "Eco", "Crash" )`.
  - `Elm.Kernel.File` and `Eco.Kernel.File` give results that are not equal.
    This test does not check what either result is.

Among what is not tested: a name that is not a kernel module name, on which
`getKernel` crashes; a home whose name contains a dot; and `Name.isKernel`.

-}

import Compiler.Data.Name as Name
import Expect
import Test exposing (Test)


{-| All of this module's tests, grouped under the label `Name.getKernel`.
-}
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
