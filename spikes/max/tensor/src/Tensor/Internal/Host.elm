module Tensor.Internal.Host exposing (paddedSize, packed, encodeValues, lcg, draws, normalDraws)

{-| Byte layouts shared with the host, element encoders for every dtype, and the generator
`Param.initial` draws from (the MNIST spike's LCG, kept so its runs stay comparable).
-}

import Bitwise
import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as Decode
import Bytes.Encode as Encode
import Tensor.Internal.Prim exposing (DT(..))


{-| `n` rounded up to a multiple of 16: every tensor in a host message starts 16-aligned.
-}
paddedSize : Int -> Int
paddedSize n =
    n + modBy 16 (16 - modBy 16 n)


packed : Bytes -> Encode.Encoder
packed b =
    let
        w =
            Bytes.width b
    in
    Encode.sequence (Encode.bytes b :: List.repeat (paddedSize w - w) (Encode.unsignedInt8 0))


{-| Values as little-endian elements of `dt`.
-}
encodeValues : DT -> List Float -> Bytes
encodeValues dt values =
    Encode.encode (Encode.sequence (List.map (element dt) values))


element : DT -> Float -> Encode.Encoder
element dt v =
    case dt of
        F32 ->
            Encode.float32 LE v

        F64 ->
            Encode.float64 LE v

        BF16 ->
            Encode.unsignedInt16 LE (bf16Bits v)

        F16 ->
            Encode.unsignedInt16 LE (f16Bits v)

        SI8 ->
            Encode.signedInt8 (round v)

        UI8 ->
            Encode.unsignedInt8 (round v)

        SI32 ->
            Encode.signedInt32 LE (round v)

        SI64 ->
            int64 (round v)

        UI64 ->
            int64 (round v)

        Bool ->
            Encode.unsignedInt8
                (if v /= 0 then
                    1

                 else
                    0
                )


int64 : Int -> Encode.Encoder
int64 n =
    let
        low =
            modBy 4294967296 n

        high =
            (n - low) // 4294967296
    in
    Encode.sequence [ Encode.unsignedInt32 LE low, Encode.signedInt32 LE high ]


f32Bits : Float -> Int
f32Bits v =
    Encode.encode (Encode.float32 LE v)
        |> Decode.decode (Decode.unsignedInt32 LE)
        |> Maybe.withDefault 0


{-| The upper half of the f32 pattern, rounded to nearest even (NaN stays NaN).
-}
bf16Bits : Float -> Int
bf16Bits v =
    let
        bits =
            f32Bits v

        upper =
            bits // 65536

        lower =
            modBy 65536 bits
    in
    if isNaN v then
        0x7FC0

    else if lower > 0x8000 || (lower == 0x8000 && modBy 2 upper == 1) then
        modBy 65536 (upper + 1)

    else
        upper


{-| IEEE half precision, round to nearest even; overflow to infinity, small values to subnormals.
-}
f16Bits : Float -> Int
f16Bits v =
    let
        bits =
            f32Bits v

        sign =
            Bitwise.and (Bitwise.shiftRightZfBy 16 bits) 0x8000

        e =
            Bitwise.and (Bitwise.shiftRightZfBy 23 bits) 0xFF

        mant =
            Bitwise.and bits 0x007FFFFF
    in
    if e == 0xFF then
        Bitwise.or sign
            (if mant /= 0 then
                0x7E00

             else
                0x7C00
            )

    else
        let
            ex =
                e - 127 + 15
        in
        if ex >= 31 then
            Bitwise.or sign 0x7C00

        else if ex <= 0 then
            if ex < -10 then
                sign

            else
                let
                    m =
                        Bitwise.or mant 0x00800000

                    shift =
                        14 - ex

                    half =
                        Bitwise.shiftLeftBy (shift - 1) 1

                    rounded =
                        roundShift m shift half
                in
                Bitwise.or sign rounded

        else
            let
                rounded =
                    roundShift mant 13 0x1000

                combined =
                    ex * 1024 + rounded
            in
            if combined >= 0x7C00 then
                Bitwise.or sign 0x7C00

            else
                Bitwise.or sign combined


roundShift : Int -> Int -> Int -> Int
roundShift m shift half =
    let
        q =
            Bitwise.shiftRightZfBy shift m

        r =
            m - Bitwise.shiftLeftBy shift q
    in
    if r > half || (r == half && modBy 2 q == 1) then
        q + 1

    else
        q


{-| A 32-bit linear congruential generator.
-}
lcg : Int -> Int
lcg seed =
    modBy 4294967296 (1664525 * seed + 1013904223)


{-| `count` values `toValue u` for uniform u in [0, 1), in the order they are written, and the
seed after them. The values are written last draw first, as the spike always has.
-}
draws : (Float -> Float) -> Int -> Int -> ( List Float, Int )
draws toValue count seed0 =
    let
        go k seed acc =
            if k == 0 then
                ( acc, seed )

            else
                let
                    s =
                        lcg seed

                    u =
                        toFloat s / 4294967296
                in
                go (k - 1) s (toValue u :: acc)
    in
    go count seed0 []


{-| `count` normal values (Box–Muller on pairs of draws), and the seed after them.
-}
normalDraws : Float -> Float -> Int -> Int -> ( List Float, Int )
normalDraws mean std count seed0 =
    let
        go k seed acc =
            if k <= 0 then
                ( List.take count acc, seed )

            else
                let
                    s1 =
                        lcg seed

                    s2 =
                        lcg s1

                    u1 =
                        (toFloat s1 + 1) / 4294967297

                    u2 =
                        toFloat s2 / 4294967296

                    r =
                        sqrt (-2 * logBase e u1)

                    a =
                        mean + std * r * cos (2 * pi * u2)

                    b =
                        mean + std * r * sin (2 * pi * u2)
                in
                go (k - 2) s2 (a :: b :: acc)
    in
    go count seed0 []
