module Compiler.Core.NameKernelTest exposing (suite)

{-| Tests for `Name.toKernel`, which splits the name of a kernel module into its
kernel prefix and its home module, or gives `Nothing` for any other name.

A kernel module is one named `Elm.Kernel.X` or `Eco.Kernel.X`; its prefix is
`Elm` or `Eco` and its home is `X`. When the canonicalizer resolves a qualified
reference into a kernel module it keeps both halves, and MLIR code generation
names the kernel's C symbol starting `<prefix>_Kernel_<home>_`. A wrong split
would make a reference name a different kernel's symbol.

The fixture is nothing more than literal module names.

The tests establish:

  - `Elm.Kernel.List` and `Elm.Kernel.Http` split into `( "Elm", "List" )` and
    `( "Elm", "Http" )`, each in a `Just`.
  - `Eco.Kernel.File`, `Eco.Kernel.Http` and `Eco.Kernel.Crash` split into
    `( "Eco", "File" )`, `( "Eco", "Http" )` and `( "Eco", "Crash" )`, each in
    a `Just`.
  - `Elm.Kernel.File` and `Eco.Kernel.File` give results that are not equal.
    This test does not check what either result is.

Among what is not tested: a name that is not a kernel module name; a home
whose name contains a dot; and `Name.isKernel`.

-}

import Compiler.Core.Name as Name
import Expect
import Test exposing (Test)


{-| All of this module's tests, grouped under the label `Name.toKernel`.
-}
suite : Test
suite =
    Test.describe "Name.toKernel"
        [ Test.test "Elm.Kernel.List returns (Elm, List)" <|
            \_ ->
                Name.toKernel "Elm.Kernel.List"
                    |> Expect.equal (Just ( "Elm", "List" ))
        , Test.test "Eco.Kernel.File returns (Eco, File)" <|
            \_ ->
                Name.toKernel "Eco.Kernel.File"
                    |> Expect.equal (Just ( "Eco", "File" ))
        , Test.test "Elm.Kernel.File and Eco.Kernel.File are distinguishable" <|
            \_ ->
                let
                    elm =
                        Name.toKernel "Elm.Kernel.File"

                    eco =
                        Name.toKernel "Eco.Kernel.File"
                in
                Expect.notEqual elm eco
        , Test.test "Elm.Kernel.Http returns (Elm, Http)" <|
            \_ ->
                Name.toKernel "Elm.Kernel.Http"
                    |> Expect.equal (Just ( "Elm", "Http" ))
        , Test.test "Eco.Kernel.Http returns (Eco, Http)" <|
            \_ ->
                Name.toKernel "Eco.Kernel.Http"
                    |> Expect.equal (Just ( "Eco", "Http" ))
        , Test.test "Eco.Kernel.Crash returns (Eco, Crash)" <|
            \_ ->
                Name.toKernel "Eco.Kernel.Crash"
                    |> Expect.equal (Just ( "Eco", "Crash" ))
        ]
