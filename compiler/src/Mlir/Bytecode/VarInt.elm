module Mlir.Bytecode.VarInt exposing (encodeVarInt, encodeSignedVarInt, varIntWidth)

{-| The MLIR bytecode format stores integers such as counts and table indices
in a variable-length form called PrefixVarInt, and this module writes that form.

A _PrefixVarInt_ is a little-endian integer of one to nine bytes whose first
byte says how long it is: the number of trailing zero bits in the first byte,
plus one, is the total number of bytes. The bits above the lowest set bit hold
the low bits of the value, and the following bytes hold the rest. A first byte
of zero therefore means eight more bytes, which hold the whole value as a
64-bit integer.

    xxxxxxx1:  7 value bits, 1 byte
    xxxxxx10: 14 value bits, 2 bytes
    xxxxx100: 21 value bits, 3 bytes
    xxxx1000: 28 value bits, 4 bytes
    xxx10000: 35 value bits, 5 bytes
    xx100000: 42 value bits, 6 bytes
    x1000000: 49 value bits, 7 bytes
    10000000: 56 value bits, 8 bytes
    00000000: 64 value bits, 9 bytes

This module writes only the 1-, 2-, 3-, 4- and 9-byte forms, and the reason is
the width of `Bitwise`. Under JavaScript, Elm's `Bitwise` operations work on
32-bit integers, so a value can be shifted into place beside its length bits
only while it fits in 28 bits. Every value at or above 2^28 is written in the
9-byte form instead, where the value is not shifted left beside length bits
but split into two unsigned 32-bit words (`Compiler.Data.Int64.toWords`). That
split is exact for every value the host holds exactly: natively every `Int`,
and under JavaScript every whole number within the 64-bit range. A negative
value is also written in the 9-byte form, as its 64-bit two's complement.

_Zigzag encoding_ maps a signed integer to an unsigned one so that values of
small magnitude stay small: 0, -1, 1, -2, 2 become 0, 1, 2, 3, 4.
`encodeSignedVarInt` applies it before writing a PrefixVarInt, on the two
32-bit words when the doubled value would not be exact under JavaScript.

@docs encodeVarInt, encodeSignedVarInt, varIntWidth

-}

import Bitwise
import Bytes
import Bytes.Encode as BE
import Compiler.Data.Int64 as Int64


{-| Creates an encoder that writes `value` as a PrefixVarInt.

A `value` from 0 to below 2^28 is written in the shortest of the 1-, 2-, 3-
and 4-byte forms that holds it. Anything larger is written in the 9-byte
form.

A negative `value` is not rejected. It is written in the 9-byte form as its
64-bit two's complement, that is, as the unsigned integer 2^64 + `value`.

-}
encodeVarInt : Int -> BE.Encoder
encodeVarInt value =
    if value < 0 then
        encode9Bytes value

    else if value < 0x80 then
        BE.unsignedInt8 (Bitwise.or (Bitwise.shiftLeftBy 1 value) 1)

    else if value < 0x4000 then
        let
            tagged =
                Bitwise.or (Bitwise.shiftLeftBy 2 value) 2
        in
        BE.sequence
            [ BE.unsignedInt8 (Bitwise.and tagged 0xFF)
            , BE.unsignedInt8 (Bitwise.and (Bitwise.shiftRightZfBy 8 tagged) 0xFF)
            ]

    else if value < 0x00200000 then
        let
            tagged =
                Bitwise.or (Bitwise.shiftLeftBy 3 value) 4
        in
        BE.sequence
            [ BE.unsignedInt8 (Bitwise.and tagged 0xFF)
            , BE.unsignedInt8 (Bitwise.and (Bitwise.shiftRightZfBy 8 tagged) 0xFF)
            , BE.unsignedInt8 (Bitwise.and (Bitwise.shiftRightZfBy 16 tagged) 0xFF)
            ]

    else if value < 0x10000000 then
        let
            -- Under JavaScript this is negative from 2^27 up; only its bytes are used.
            tagged =
                Bitwise.or (Bitwise.shiftLeftBy 4 value) 8
        in
        BE.sequence
            [ BE.unsignedInt8 (Bitwise.and tagged 0xFF)
            , BE.unsignedInt8 (Bitwise.and (Bitwise.shiftRightZfBy 8 tagged) 0xFF)
            , BE.unsignedInt8 (Bitwise.and (Bitwise.shiftRightZfBy 16 tagged) 0xFF)
            , BE.unsignedInt8 (Bitwise.and (Bitwise.shiftRightZfBy 24 tagged) 0xFF)
            ]

    else
        encodeLargeVarInt value


{-| Returns the number of bytes `encodeVarInt value` writes: 1 to 4 for a
`value` from 0 to below 2^28, and 9 for one at or above 2^28 or negative.

It repeats the thresholds of `encodeVarInt` rather than sharing them, so the
two must be changed together.

-}
varIntWidth : Int -> Int
varIntWidth value =
    if value < 0 then
        9

    else if value < 0x80 then
        1

    else if value < 0x4000 then
        2

    else if value < 0x00200000 then
        3

    else if value < 0x10000000 then
        4

    else
        9


{-| Creates an encoder that writes `value` in the 9-byte form. `encodeVarInt`
uses it for every value at or above 2^28, and it does nothing beyond
`encode9Bytes`.
-}
encodeLargeVarInt : Int -> BE.Encoder
encodeLargeVarInt value =
    encode9Bytes value


{-| Creates an encoder that writes `value` in the 9-byte form: a zero byte, then
`value` as a 64-bit little-endian two's complement integer, exact for every
value the host holds exactly.
-}
encode9Bytes : Int -> BE.Encoder
encode9Bytes value =
    let
        ( hi, lo ) =
            Int64.toWords value
    in
    encodeWords9 hi lo


{-| Creates an encoder that writes the 9-byte form of the 64-bit value whose
unsigned 32-bit words are `hi` and `lo`.
-}
encodeWords9 : Int -> Int -> BE.Encoder
encodeWords9 hi lo =
    BE.sequence
        [ BE.unsignedInt8 0x00
        , BE.unsignedInt32 Bytes.LE lo
        , BE.unsignedInt32 Bytes.LE hi
        ]


{-| Creates an encoder that writes `value` zigzag-encoded as a PrefixVarInt: a
`value` of zero or more becomes `2 * value`, and a negative one becomes
`-2 * value - 1`, both taken as unsigned 64-bit integers.

When the magnitude of `value` is below 2^52 the doubled value is below 2^53 and
is computed directly, exact on both hosts. Otherwise the zigzag is computed as
`(value << 1) ^ (value >> 63)` on the two 32-bit words of `value` and written
in the 9-byte form, so every 64-bit value, `-2^63` included, is exact.

-}
encodeSignedVarInt : Int -> BE.Encoder
encodeSignedVarInt value =
    if value >= 0 && value < 0x0010000000000000 then
        encodeVarInt (value * 2)

    else if value < 0 && value > -0x0010000000000000 then
        encodeVarInt (-2 * value - 1)

    else
        let
            ( hi, lo ) =
                Int64.toWords value

            shiftedHi : Int
            shiftedHi =
                Bitwise.or (Bitwise.shiftLeftBy 1 hi) (Bitwise.shiftRightZfBy 31 lo)

            shiftedLo : Int
            shiftedLo =
                Bitwise.shiftLeftBy 1 lo

            sign : Int
            sign =
                if value < 0 then
                    0xFFFFFFFF

                else
                    0
        in
        encodeWords9 (u32 (Bitwise.xor shiftedHi sign)) (u32 (Bitwise.xor shiftedLo sign))


{-| Returns the low 32 bits of `x` as an unsigned number, on either host.
-}
u32 : Int -> Int
u32 x =
    Bitwise.shiftRightZfBy 0 (Bitwise.and x 0xFFFFFFFF)
