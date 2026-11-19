module Compiler.GenerateJs.KernelOverrideTest exposing (suite)

{-| `Compiler.GenerateJs.KernelOverride.section` chooses the kernel overrides a program calls for and
lays them out (plans/js-kernel-overrides.md §3.2).

The fixtures are three overrides: `A` needs `Elm.Kernel.Bytes`, `B` needs `Elm.Kernel.Json`, and `C`
needs both. The tests check that an override is chosen only when every kernel module it requires is
present, that the chosen ones keep their input order after one `marker` line, and that nothing at all
is emitted when none is chosen, so a program that needs no override gets no extra lines. One more test
checks that the generated `Files.all` is sorted by file name, as the generator promises.

Not tested here: where `Compiler.GenerateJs.Generate` puts the section and the source-map offset that
counts it, which test/scripts/js-kernel-overrides.test.js checks on compiled programs.

-}

import Compiler.GenerateJs.KernelOverride as KernelOverride
import Compiler.GenerateJs.KernelOverride.Files as Files
import Expect
import Test exposing (Test, describe, test)


overrides : List Files.KernelOverride
overrides =
    [ { file = "A.js", requires = [ ( "Elm", "Bytes" ) ], text = "a = 1;\n" }
    , { file = "B.js", requires = [ ( "Elm", "Json" ) ], text = "b = 2;\n" }
    , { file = "C.js", requires = [ ( "Elm", "Bytes" ), ( "Elm", "Json" ) ], text = "c = 3;\n" }
    ]


{-| A presence test that answers yes for the listed kernel modules only.
-}
presentOnly : List ( String, String ) -> ( String, String ) -> Bool
presentOnly present kernel =
    List.member kernel present


suite : Test
suite =
    describe "KernelOverride.section"
        [ test "nothing is emitted when no override is chosen" <|
            \_ ->
                KernelOverride.section (presentOnly [ ( "Elm", "Utils" ) ]) overrides
                    |> Expect.equal ""
        , test "an override is chosen only when all its kernel modules are present" <|
            \_ ->
                KernelOverride.section (presentOnly [ ( "Elm", "Bytes" ) ]) overrides
                    |> Expect.equal ("\n" ++ KernelOverride.marker ++ "a = 1;\n")
        , test "the chosen overrides keep their order after one marker" <|
            \_ ->
                KernelOverride.section (presentOnly [ ( "Elm", "Bytes" ), ( "Elm", "Json" ) ]) overrides
                    |> Expect.equal ("\n" ++ KernelOverride.marker ++ "a = 1;\nb = 2;\nc = 3;\n")
        , test "an Eco kernel module is told apart from an Elm one of the same home" <|
            \_ ->
                KernelOverride.section (presentOnly [ ( "Eco", "Bytes" ) ]) overrides
                    |> Expect.equal ""
        , test "the generated overrides are sorted by file name" <|
            \_ ->
                List.map .file Files.all
                    |> Expect.equal (List.sort (List.map .file Files.all))
        ]
