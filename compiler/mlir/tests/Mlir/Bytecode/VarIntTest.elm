module Mlir.Bytecode.VarIntTest exposing (suite)

{-| Regression tests for `Mlir.Bytecode.VarInt`, run under the JavaScript
backend that elm-test runs on.

The negative zigzag case used to be computed as `Bitwise.xor (value * 2) -1`,
and under JavaScript `Bitwise.xor` truncates `value * 2` to 32 bits, so for
`value < -2^30` the number written was not the zigzag encoding
`-2 * value - 1` (-2^31 was written as -1 instead of 2^32 - 1). The first four
tests pin the fix. The rest pin the 9-byte form at full 64-bit width, beyond
the 2^53 that a double holds: the zigzag of -2^63 is 2^64 - 1, of -2^60 is
2^61 - 1 and of 2^60 is 2^61, and `encodeVarInt` writes -1 as eight bytes of
ones and 2^40 + 5 exactly.

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
        , expectBytes "zigzag of -2^63 is 2^64 - 1"
            (encodeSignedVarInt (-4611686018427387904 * 2))
            (0 :: List.repeat 8 255)
        , expectBytes "zigzag of -2^60 is 2^61 - 1"
            (encodeSignedVarInt -1152921504606846976)
            [ 0, 255, 255, 255, 255, 255, 255, 255, 0x1F ]
        , expectBytes "zigzag of 2^60 is 2^61"
            (encodeSignedVarInt 1152921504606846976)
            [ 0, 0, 0, 0, 0, 0, 0, 0, 0x20 ]
        , expectBytes "varint of -1 is nine bytes, eight of ones"
            (encodeVarInt -1)
            (0 :: List.repeat 8 255)
        , expectBytes "varint of 2^40 + 5"
            (encodeVarInt 1099511627781)
            [ 0, 5, 0, 0, 0, 0, 1, 0, 0 ]
        ]


expectBytes : String -> BE.Encoder -> List Int -> Test
expectBytes name encoder expected =
    Test.test name <|
        \_ ->
            toList (BE.encode encoder)
                |> Expect.equal expected
