module Compiler.Data.Int64 exposing (hostIs64, toWords, fromWords, fromLiteral)

{-| Exact 64-bit two's-complement arithmetic for Int literals, on both hosts of
the compiler.

Eco's `Int` is a signed 64-bit integer. The compiler itself runs either natively
(its `Int` is that same i64, and `Bitwise` is 64-bit, CGEN\_085) or as
JavaScript (its `Int` is a double: exact only within 2^53, and `Bitwise` works
on 32 bits). A literal's value is defined as its digits taken modulo 2^64 and
read as two's complement, so `0xFFFFFFFFFFFFFFFF` is `-1`.

This module works on the value as two unsigned 32-bit words `( hi, lo )`, which
both hosts hold exactly, and converts to and from an `Int` only where the host
can hold the result exactly.

@docs hostIs64, toWords, fromWords, fromLiteral

-}

import Bitwise


{-| Whether the compiler runs with a 64-bit `Int` (native) rather than a double
(JavaScript). Under JavaScript a shift counts modulo 32, so `1 << 32` is `1`;
natively it counts modulo 64 (CGEN\_085). Evaluated at run time: the front end
folds no Bitwise call.
-}
hostIs64 : Bool
hostIs64 =
    Bitwise.shiftLeftBy 32 1 /= 1


two32 : Int
two32 =
    4294967296


{-| Keeps the low 32 bits of `x` as an unsigned number, on either host.
-}
u32 : Int -> Int
u32 x =
    Bitwise.shiftRightZfBy 0 (Bitwise.and x 0xFFFFFFFF)


{-| Returns `value` as its 64-bit two's complement, split into an unsigned high
and low word. Exact for every `Int` the host holds exactly (natively all of
them; under JavaScript every whole double within the i64 range).
-}
toWords : Int -> ( Int, Int )
toWords value =
    if hostIs64 then
        ( u32 (Bitwise.shiftRightBy 32 value), u32 value )

    else
        let
            -- Division by a power of two and floor are exact on a double.
            hiSigned =
                floor (toFloat value / toFloat two32)
        in
        ( u32 hiSigned, value - hiSigned * two32 )


{-| Returns the `Int` whose 64-bit two's complement is the words `( hi, lo )`,
or `Nothing` when the host cannot hold it exactly (under JavaScript, a value
with more than 53 significant bits).
-}
fromWords : Int -> Int -> Maybe Int
fromWords hi lo =
    if hostIs64 then
        Just (Bitwise.or (Bitwise.shiftLeftBy 32 hi) lo)

    else
        let
            hiSigned =
                if hi >= 0x80000000 then
                    hi - two32

                else
                    hi

            value =
                hiSigned * two32 + lo
        in
        if toWords value == ( hi, lo ) then
            Just value

        else
            Nothing


{-| Returns the value of an integer literal's source text, decimal or `0x`
hexadecimal, taken modulo 2^64 as two's complement, or `Nothing` when the host
cannot hold that value exactly. The text is assumed well formed (the parser has
already scanned it).
-}
fromLiteral : String -> Maybe Int
fromLiteral text =
    let
        ( hi, lo ) =
            if String.startsWith "0x" text then
                String.foldl (\c acc -> mulAdd 16 (hexValue c) acc) ( 0, 0 ) (String.dropLeft 2 text)

            else
                String.foldl (\c acc -> mulAdd 10 (Char.toCode c - 48) acc) ( 0, 0 ) text
    in
    fromWords hi lo


{-| `( hi, lo ) * m + d` modulo 2^64, for `m` and `d` below 2^5. Every
intermediate is below 2^37, exact on both hosts.
-}
mulAdd : Int -> Int -> ( Int, Int ) -> ( Int, Int )
mulAdd m d ( hi, lo ) =
    let
        loFull =
            lo * m + d

        carry =
            floor (toFloat loFull / toFloat two32)

        hiLow16 =
            Bitwise.and hi 0xFFFF

        hiHigh16 =
            Bitwise.shiftRightZfBy 16 hi

        -- hi * m + carry, modulo 2^32, done in two 16-bit halves.
        newLow =
            hiLow16 * m + carry

        newHigh =
            Bitwise.and (hiHigh16 * m + floor (toFloat newLow / 65536)) 0xFFFF
    in
    ( u32 (newHigh * 65536 + Bitwise.and newLow 0xFFFF), loFull - carry * two32 )


hexValue : Char -> Int
hexValue c =
    let
        code =
            Char.toCode c
    in
    if code <= 0x39 then
        code - 0x30

    else if code <= 0x46 then
        code - 0x37

    else
        code - 0x57
