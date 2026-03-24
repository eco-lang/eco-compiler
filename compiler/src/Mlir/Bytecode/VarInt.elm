module Mlir.Bytecode.VarInt exposing (encodeVarInt, encodeSignedVarInt)

{-| PrefixVarInt encoding for the MLIR bytecode format.

Each VarInt uses a prefix bit pattern in the first byte to indicate the total
number of bytes. The encoding is little-endian with the remaining bits of the
first byte contributing to the value.

    xxxxxxx1:  7 value bits, 1 byte
    xxxxxx10: 14 value bits, 2 bytes
    xxxxx100: 21 value bits, 3 bytes
    xxxx1000: 28 value bits, 4 bytes
    xxx10000: 35 value bits, 5 bytes
    xx100000: 42 value bits, 6 bytes
    x1000000: 49 value bits, 7 bytes
    10000000: 56 value bits, 8 bytes
    00000000: 64 value bits, 9 bytes

Signed VarInts use zigzag encoding: (value << 1) ^ (value >> 63)

@docs encodeVarInt, encodeSignedVarInt

-}

import Bitwise
import Bytes.Encode as BE


{-| Encode an unsigned integer as a PrefixVarInt.
-}
encodeVarInt : Int -> BE.Encoder
encodeVarInt value =
    if value < 0 then
        -- Negative values treated as large unsigned; use 9-byte encoding
        encode9Bytes value

    else if value < 0x80 then
        -- 7 value bits, 1 byte: value << 1 | 1
        BE.unsignedInt8 (Bitwise.or (Bitwise.shiftLeftBy 1 value) 1)

    else if value < 0x4000 then
        -- 14 value bits, 2 bytes: prefix = 10
        let
            tagged =
                Bitwise.or (Bitwise.shiftLeftBy 2 value) 2
        in
        BE.sequence
            [ BE.unsignedInt8 (Bitwise.and tagged 0xFF)
            , BE.unsignedInt8 (Bitwise.and (Bitwise.shiftRightZfBy 8 tagged) 0xFF)
            ]

    else if value < 0x00200000 then
        -- 21 value bits, 3 bytes: prefix = 100
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
        -- 28 value bits, 4 bytes: prefix = 1000
        let
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
        -- For values >= 2^28, use multi-word encoding
        encodeLargeVarInt value


{-| Encode values >= 2^28 using the 9-byte encoding.
We skip the 5/6/7-byte encodings because JS bitwise operators truncate to 32 bits,
causing corruption when shifting values >= 2^27. The 9-byte encoding avoids this
by extracting bytes without shifts on the full value.
-}
encodeLargeVarInt : Int -> BE.Encoder
encodeLargeVarInt value =
    encode9Bytes value


{-| 9-byte encoding: first byte is 0x00, then 8 bytes of raw little-endian value.
Used for values >= 2^49 or negative values (which in JS are large when unsigned).
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


{-| Encode a signed integer using zigzag encoding, then PrefixVarInt.
Zigzag maps signed values to unsigned: 0 -> 0, -1 -> 1, 1 -> 2, -2 -> 3, etc.
-}
encodeSignedVarInt : Int -> BE.Encoder
encodeSignedVarInt value =
    let
        -- Zigzag encoding: (value << 1) ^ (value >> 63)
        -- For JS compatibility (32-bit bitwise ops), we compute the sign extension manually:
        -- For non-negative values, (value >> 63) = 0, so zigzag = value << 1
        -- For negative values, (value >> 63) = -1 (all 1s), so zigzag = (value << 1) ^ -1
        zigzag =
            if value >= 0 then
                value * 2

            else
                Bitwise.xor (value * 2) -1
    in
    encodeVarInt zigzag


{-| Arithmetic shift right, preserving the sign bit.
Elm's Bitwise.shiftRightBy is arithmetic but capped at 32 bits.
For shifts > 31, we use repeated division to avoid JS 32-bit truncation.
-}
shiftRightBy : Int -> Int -> Int
shiftRightBy amount value =
    if amount <= 31 then
        Bitwise.shiftRightBy amount value

    else
        -- Can't use Bitwise.shiftLeftBy for the divisor because JS truncates
        -- shifts to 32 bits (1 << 32 = 1, not 4294967296).
        -- Use powers of 2 via multiplication instead.
        let
            divisor =
                powOf2 amount
        in
        floor (toFloat value / divisor)


{-| Compute 2^n as a Float. Safe for n up to 52 (JS float64 precision).
-}
powOf2 : Int -> Float
powOf2 n =
    if n <= 0 then
        1.0

    else if n <= 30 then
        toFloat (Bitwise.shiftLeftBy n 1)

    else
        -- For n > 30, build up by doubling
        toFloat (Bitwise.shiftLeftBy 30 1) * powOf2 (n - 30)
