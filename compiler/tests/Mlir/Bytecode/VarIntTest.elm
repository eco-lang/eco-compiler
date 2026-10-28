module Mlir.Bytecode.VarIntTest exposing (suite)

{-| Regression test for `Mlir.Bytecode.VarInt.encodeSignedVarInt`. EXPECTED TO
FAIL (under the JavaScript backend that elm-test runs on) until the bug is
fixed.

Bug reproduced: the negative zigzag case is computed as
`Bitwise.xor (value * 2) -1`, and under JavaScript `Bitwise.xor` truncates
`value * 2` to 32 bits. For `value < -2^30` the number written is not the
zigzag encoding `-2 * value - 1`; e.g. -2^31 is written as -1 (a 9-byte
two's complement) instead of 2^32 - 1, and -2^31 - 1 as 1 instead of 2^32 + 1.

-}

import Bytes exposing (Bytes)
import Bytes.Decode as BD
import Bytes.Encode as BE
import Expect
import Mlir.Bytecode.VarInt exposing (encodeSignedVarInt, encodeVarInt)
import Test exposing (Test)


expectZigzag : Int -> Test
expectZigzag value =
    Test.test ("zigzag of " ++ String.fromInt value ++ " is " ++ String.fromInt (-2 * value - 1)) <|
        \_ ->
            toList (BE.encode (encodeSignedVarInt value))
                |> Expect.equal (toList (BE.encode (encodeVarInt (-2 * value - 1))))


{-| The bytes as a list (`==` on `Bytes` does not compare contents).
-}
toList : Bytes -> List Int
toList bytes =
    BD.decode (BD.loop ( Bytes.width bytes, [] ) step) bytes
        |> Maybe.withDefault []


step : ( Int, List Int ) -> BD.Decoder (BD.Step ( Int, List Int ) (List Int))
step ( n, acc ) =
    if n <= 0 then
        BD.succeed (BD.Done (List.reverse acc))

    else
        BD.map (\b -> BD.Loop ( n - 1, b :: acc )) BD.unsignedInt8


suite : Test
suite =
    Test.describe "Mlir.Bytecode.VarInt signed encoding regressions"
        [ expectZigzag -1073741825
        , expectZigzag -2147483648
        , expectZigzag -2147483649
        , expectZigzag -4294967299
        ]
