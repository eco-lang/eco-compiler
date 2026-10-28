module Compiler.Json.EncodeTest exposing (suite)

{-| Regression tests for `Compiler.Json.Encode` escaping. EXPECTED TO FAIL until
the bugs are fixed.

`escape` handles only CR, LF, `"` and `\`; any other character below U+0020 is
written raw, which is not valid JSON. Reached by `eco make --docs` on a doc
comment holding U+0001 (test/scripts/cli-builder.test.js). Validity is checked
with `elm/json`.

-}

import Compiler.Json.Encode as E
import Expect
import Json.Decode
import Test exposing (Test)


isValidJson : String -> Bool
isValidJson s =
    case Json.Decode.decodeString Json.Decode.value s of
        Ok _ ->
            True

        Err _ ->
            False


suite : Test
suite =
    Test.describe "Compiler.Json.Encode"
        [ Test.test "a string with U+0001 encodes to valid JSON" <|
            \_ ->
                E.encodeUgly (E.chars "a\u{0001}b")
                    |> isValidJson
                    |> Expect.equal True
        ]
