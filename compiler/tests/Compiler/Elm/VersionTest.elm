module Compiler.Elm.VersionTest exposing (suite)

{-| Regression test for `Compiler.Elm.Version` number parsing.

`chompWord16` once accumulated `10 * total + digit` with no bound, so a
component such as `99999999999999999999` was accepted: an inexact float under
JS, a wrapped (possibly negative) Int64 natively. A component above 65535 is
now rejected (the reference compiler's components are Word16).

-}

import Compiler.Elm.Version as V
import Compiler.Json.Decode as D
import Expect
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Compiler.Elm.Version.decoder"
        [ Test.test "an over-long component is rejected" <|
            \_ ->
                D.fromByteString V.decoder "\"1.0.99999999999999999999\""
                    |> Result.toMaybe
                    |> Maybe.map V.toChars
                    |> Expect.equal Nothing
        ]
