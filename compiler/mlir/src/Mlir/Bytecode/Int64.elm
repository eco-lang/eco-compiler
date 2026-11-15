module Mlir.Bytecode.Int64 exposing (toWords)

{-| Splits an `Int` into the two 32-bit words of its 64-bit two's complement, the same on every
host Elm runs on.

Bytecode writes 64-bit integers, but an Elm `Int` is not 64 bits everywhere. Compiled natively, as
eco compiles it, an `Int` is a signed 64-bit integer and `Bitwise` works on 64 bits. Compiled to
JavaScript it is a double, exact only within ±2⁵³, and `Bitwise` works on 32 bits. Both hosts hold
an unsigned 32-bit word exactly, so the encoders work on `( hi, lo )` word pairs.

@docs toWords

-}

import Bitwise


{-| Whether `Int` is 64 bits (native) rather than a double (JavaScript). Under JavaScript a shift
counts modulo 32, so `1 << 32` is `1`; natively it counts modulo 64. Evaluated at run time.
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


{-| Returns `value` as its 64-bit two's complement, split into an unsigned high and low word.
Exact for every `Int` the host holds exactly (natively all of them; under JavaScript every whole
double within the 64-bit range).
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
