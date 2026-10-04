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
and the upper four bytes are found by dividing. That division goes through a
`Float`, so the 9-byte form is exact while the magnitude of the value is at
most 2^53. A negative value is also written in the 9-byte form, as its 64-bit
two's complement.

_Zigzag encoding_ maps a signed integer to an unsigned one so that values of
small magnitude stay small: 0, -1, 1, -2, 2 become 0, 1, 2, 3, 4.
`encodeSignedVarInt` applies it before writing a PrefixVarInt.

@docs encodeVarInt, encodeSignedVarInt, varIntWidth

-}

import Bitwise
import Bytes.Encode as BE


{-| Creates an encoder that writes `value` as a PrefixVarInt.

A `value` from 0 to below 2^28 is written in the shortest of the 1-, 2-, 3-
and 4-byte forms that holds it. Anything larger is written in the 9-byte
form, exact while it is at most 2^53.

A negative `value` is not rejected. It is written in the 9-byte form as its
64-bit two's complement, that is, as the unsigned integer 2^64 + `value`,
exact while its magnitude is at most 2^53.

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
`value` as a 64-bit little-endian two's complement integer.

The upper four bytes come from `shiftRightBy`, which divides through a `Float`
for these shift amounts, so the result is exact while the magnitude of `value`
is at most 2^53.

-}
encode9Bytes : Int -> BE.Encoder
encode9Bytes value =
    BE.sequence
        [ BE.unsignedInt8 0x00
        , BE.unsignedInt8 (Bitwise.and value 0xFF)
        , BE.unsignedInt8 (Bitwise.and (Bitwise.shiftRightZfBy 8 value) 0xFF)
        , BE.unsignedInt8 (Bitwise.and (Bitwise.shiftRightZfBy 16 value) 0xFF)
        , BE.unsignedInt8 (Bitwise.and (Bitwise.shiftRightZfBy 24 value) 0xFF)
        , BE.unsignedInt8 (Bitwise.and (shiftRightBy 32 value) 0xFF)
        , BE.unsignedInt8 (Bitwise.and (shiftRightBy 40 value) 0xFF)
        , BE.unsignedInt8 (Bitwise.and (shiftRightBy 48 value) 0xFF)
        , BE.unsignedInt8 (Bitwise.and (shiftRightBy 56 value) 0xFF)
        ]


{-| Creates an encoder that writes `value` zigzag-encoded as a PrefixVarInt: a
`value` of zero or more becomes `2 * value`, and a negative one becomes
`-2 * value - 1`.

The negative case is computed as `Bitwise.xor (value * 2) -1`. Under
JavaScript that is right only while `value * 2` fits in a signed 32-bit
integer, that is, for `value` down to -2^30. Below that the doubled value
wraps to 32 bits before the xor, so the number written is not the zigzag
encoding of `value`.

-}
encodeSignedVarInt : Int -> BE.Encoder
encodeSignedVarInt value =
    let
        -- (value << 1) ^ (value >> 63), with the sign word chosen by case.
        zigzag =
            if value >= 0 then
                value * 2

            else
                Bitwise.xor (value * 2) -1
    in
    encodeVarInt zigzag


{-| Returns `value` shifted right by `amount` bits, rounding toward negative
infinity as an arithmetic shift does.

Shifts of up to 31 bits use `Bitwise.shiftRightBy`. Longer ones divide by
2^`amount` as a `Float` and take the floor, because under JavaScript
`Bitwise.shiftRightBy` works on 32 bits. The division is exact while the
magnitude of `value` is at most 2^53.

Under JavaScript a shift of up to 31 bits is right only for a `value` that fits
in a signed 32-bit integer. `encode9Bytes` calls this only with shifts of 32 or
more.

-}
shiftRightBy : Int -> Int -> Int
shiftRightBy amount value =
    if amount <= 31 then
        Bitwise.shiftRightBy amount value

    else
        let
            divisor =
                powOf2 amount
        in
        floor (toFloat value / divisor)


{-| Returns 2^`n` as a `Float`, or 1.0 for an `n` of zero or less.

Above 30 it multiplies by 2^30 as many times as needed rather than shifting,
because under JavaScript `Bitwise.shiftLeftBy` works on 32 bits, and
`1 << 32` is 1.

-}
powOf2 : Int -> Float
powOf2 n =
    if n <= 0 then
        1.0

    else if n <= 30 then
        toFloat (Bitwise.shiftLeftBy n 1)

    else
        toFloat (Bitwise.shiftLeftBy 30 1) * powOf2 (n - 30)
