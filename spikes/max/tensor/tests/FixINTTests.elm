module FixINTTests exposing (suite)

{-| Integer values beyond ±2⁵³, keys of large integer constants, the text of `ui64` elements of
2⁶³ or more, NaN `Int`s and negative draw counts.

elm-test-rs runs these under JavaScript, where an `Int` is a double. Every integer used is a
double exactly, and lies in −2⁶³ … 2⁶³ − 1, so it is the same number in a native 64-bit build; the
expected results are the native ones, written out piece by piece where they are pieces. The NaN
test is the one that has no native counterpart (`round (0/0)` is NaN only under JavaScript).

Among what is not tested: integers that JavaScript does not hold exactly, which differ between the
two builds before any of this code sees them; `Mo` text of `si64` constants beyond ±2⁵³; and NaN or
infinite `Int`s anywhere but `fitsDtype`.

What the tests establish:

  - **u64Text.** `Values.u64Text` writes −1, −1024, −2⁶⁰ and −2⁶³ as the unsigned decimal of their
    64 bits, and 0 and 2⁶³ − 1024 as they are; `Values.decimalText` writes 2⁶³ − 1024, −2⁶⁰, −2⁶³
    and −5 in signed decimal; and `Mo.constText` writes a `ui64` −1 as 2⁶⁴ − 1.
  - **limbs and altHash.** `Values.limbs` splits 2⁶⁰, −2⁶⁰, −2⁶³ and 2⁶³ − 1024 into the 16-bit
    pieces of their 64-bit patterns, and `Values.altHash` tells `[2⁶⁰]` from `[2⁶¹]`.
  - **Keys.** `Key.mixInt64s` mixes 2⁶⁰ and −2⁶³ as the marker 65536 and the four pieces of their
    patterns; two `si64` constants holding 2⁶⁰ and 2⁶¹ have different keys and different
    `Expr.shallow` descriptions, and adding them in `Tensor.Eval` gives 3 · 2⁶⁰.
  - **Bytes.** `Encode.encodeValues` writes `si64` 2⁶⁰, −2⁶³ and 2⁶³ − 1024 as the low and then
    the high 32-bit word of each pattern.
  - **Draws.** `Encode.draws` with a negative count gives no values and returns the seed.
  - **fitsDtype.** A NaN `Int` does not fit `si32`.

-}

import Bytes exposing (Endianness(..))
import Bytes.Decode as Decode
import Expect
import Tensor.Eval as Eval
import Tensor.Internal.Encode as Encode
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Key as K
import Tensor.Internal.Mo as Mo
import Tensor.Internal.Ops as O
import Tensor.Internal.Prim exposing (DT(..))
import Tensor.Internal.Types as I
import Tensor.Internal.Values as Values exposing (Values(..))
import Test exposing (Test, describe, test)


p60 : Int
p60 =
    1152921504606846976


p61 : Int
p61 =
    2305843009213693952


{-| −2⁶³, written so that neither build has to read the literal 2⁶³.
-}
minInt : Int
minInt =
    -9223372036854775807 - 1


{-| 2⁶³ − 1024, the largest double below 2⁶³.
-}
topInt : Int
topInt =
    9223372036854774784


si64 : Int -> Expr
si64 n =
    E.constValues SI64 [ 1 ] (IntValues [ n ])


pieces : List Int -> K.Key -> K.Key
pieces l k =
    List.foldl K.mix (K.mix 65536 k) l


{-| Reads one more little-endian unsigned 32-bit word into the list, until the count left is 0.
-}
word : ( Int, List Int ) -> Decode.Decoder (Decode.Step ( Int, List Int ) (List Int))
word ( left, acc ) =
    if left == 0 then
        Decode.succeed (Decode.Done (List.reverse acc))

    else
        Decode.map (\w -> Decode.Loop ( left - 1, w :: acc )) (Decode.unsignedInt32 LE)


suite : Test
suite =
    describe "FixINT"
        [ describe "B024 u64Text"
            [ test "-1" <| \_ -> Values.u64Text -1 |> Expect.equal "18446744073709551615"
            , test "-1024" <| \_ -> Values.u64Text -1024 |> Expect.equal "18446744073709550592"
            , test "-2^60" <| \_ -> Values.u64Text -p60 |> Expect.equal "17293822569102704640"
            , test "-2^63" <| \_ -> Values.u64Text minInt |> Expect.equal "9223372036854775808"
            , test "0 and 2^63 - 1024 as they are" <|
                \_ -> List.map Values.u64Text [ 0, topInt ] |> Expect.equal [ "0", "9223372036854774784" ]
            , test "decimalText writes 2^63 - 1024, -2^60 and -2^63 in full" <|
                \_ ->
                    List.map Values.decimalText [ topInt, -p60, minInt, -5 ]
                        |> Expect.equal [ "9223372036854774784", "-1152921504606846976", "-9223372036854775808", "-5" ]
            , test "Mo.constText ui64 -1" <|
                \_ ->
                    Mo.constText UI64 [ 1 ] (IntValues [ -1 ])
                        |> Expect.equal "#M.dense_array<18446744073709551615> : tensor<1xui64>"
            ]
        , describe "B046 limbs and altHash"
            [ test "limbs 2^60" <| \_ -> Values.limbs p60 |> Expect.equal [ 0, 0, 0, 4096 ]
            , test "limbs -2^60" <| \_ -> Values.limbs -p60 |> Expect.equal [ 0, 0, 0, 61440 ]
            , test "limbs -2^63" <| \_ -> Values.limbs minInt |> Expect.equal [ 0, 0, 0, 32768 ]
            , test "limbs 2^63 - 1024" <| \_ -> Values.limbs topInt |> Expect.equal [ 64512, 65535, 65535, 32767 ]
            , test "limbs -2^53 - 2" <| \_ -> Values.limbs (-9007199254740992 - 2) |> Expect.equal [ 65534, 65535, 65535, 65503 ]
            , test "altHash [2^60] /= altHash [2^61]" <|
                \_ -> Values.altHash (IntValues [ p60 ]) |> Expect.notEqual (Values.altHash (IntValues [ p61 ]))
            ]
        , describe "B045 keys of large integers"
            [ test "mixInt64s [2^60] mixes the pieces of its pattern" <|
                \_ -> K.mixInt64s [ p60 ] (K.start "t") |> Expect.equal (pieces [ 0, 0, 0, 4096 ] (K.mix 1 (K.start "t")))
            , test "mixInt64s [-2^63] mixes the pieces of its pattern" <|
                \_ -> K.mixInt64s [ minInt ] (K.start "t") |> Expect.equal (pieces [ 0, 0, 0, 32768 ] (K.mix 1 (K.start "t")))
            , test "mixInt64s [2^63 - 1024] mixes the pieces of its pattern" <|
                \_ -> K.mixInt64s [ topInt ] (K.start "t") |> Expect.equal (pieces [ 64512, 65535, 65535, 32767 ] (K.mix 1 (K.start "t")))
            , test "si64 constants 2^60 and 2^61 have different keys" <|
                \_ -> E.key (si64 p60) |> Expect.notEqual (E.key (si64 p61))
            , test "si64 constants 2^60 and 2^61 have different shallow descriptions" <|
                \_ -> E.shallow (si64 p60) |> Expect.notEqual (E.shallow (si64 p61))
            , test "2^60 + 2^61 is not merged into 2^61 + 2^61" <|
                \_ -> Eval.ints (I.Tensor (O.add (si64 p60) (si64 p61))) |> Expect.equal (Ok [ p60 + p61 ])
            ]
        , describe "64-bit bytes"
            [ test "encodeValues si64 writes the low and high words of 2^60, -2^63 and 2^63 - 1024" <|
                \_ ->
                    Encode.encodeValues SI64 (IntValues [ p60, minInt, topInt ])
                        |> Decode.decode (Decode.loop ( 6, [] ) word)
                        |> Expect.equal (Just [ 0, 268435456, 0, 2147483648, 4294966272, 2147483647 ])
            ]
        , describe "B042 draws"
            [ test "a negative count gives no values and the seed" <|
                \_ -> Encode.draws identity -3 7 |> Expect.equal ( [], 7 )
            ]
        , describe "B084 fitsDtype"
            [ test "a NaN Int does not fit si32" <|
                \_ -> Values.fitsDtype SI32 (IntValues [ round (0 / 0) ]) |> Expect.equal (Just "value NaN does not fit si32")
            ]
        ]
