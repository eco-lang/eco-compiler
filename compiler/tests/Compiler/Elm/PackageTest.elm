module Compiler.Elm.PackageTest exposing (suite)

{-| Regression test for `Compiler.Elm.Package` name parsing. EXPECTED TO FAIL
until the bug is fixed.

`chompName` returns success when it stops at a character that is not part of a
name even if the previous character was a dash, so an author ending in a dash
(`elm-/core`) is accepted. A trailing dash is only rejected at the end of the
input (`elm/core-` is rejected).

-}

import Compiler.Elm.Package as Pkg
import Compiler.Json.Decode as D
import Expect
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Compiler.Elm.Package.decoder"
        [ Test.test "an author ending in a dash is rejected" <|
            \_ ->
                D.fromByteString Pkg.decoder "\"elm-/core\""
                    |> Result.toMaybe
                    |> Maybe.map Pkg.toChars
                    |> Expect.equal Nothing
        , Test.test "a project ending in a dash is rejected (control)" <|
            \_ ->
                D.fromByteString Pkg.decoder "\"elm/core-\""
                    |> Result.toMaybe
                    |> Maybe.map Pkg.toChars
                    |> Expect.equal Nothing
        ]
