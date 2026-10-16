module Popcount exposing (bench)

{-| Bit counting over `0 .. n-1`, pure `Bitwise` on values below 2^31: the population count by
clearing the lowest set bit (`x & (x - 1)`), the number of trailing zeros by testing bits, and a
31-bit reversal by shifting bits out and in.

Checked at every size in closed form: the total population count is, bit by bit, the number of
values below `n` with that bit set; the total of the trailing zeros of `1 .. n-1` is
`(n - 1) - popcount (n - 1)` (Legendre's formula for the exponent of 2 in `(n - 1)!`); and
reversing twice must give back every value.

-}

import Bitwise


popcount : Int -> Int
popcount x =
    let
        go v count =
            if v == 0 then
                count

            else
                go (Bitwise.and v (v - 1)) (count + 1)
    in
    go x 0


trailingZeros : Int -> Int
trailingZeros x =
    let
        go v count =
            if Bitwise.and v 1 == 1 then
                count

            else
                go (Bitwise.shiftRightZfBy 1 v) (count + 1)
    in
    if x == 0 then
        0

    else
        go x 0


{-| The low 31 bits of `x`, reversed. The result is built by arithmetic, not `shiftLeftBy`, so
it never needs bit 31.
-}
reverse31 : Int -> Int
reverse31 x =
    let
        go i v acc =
            if i >= 31 then
                acc

            else
                go (i + 1) (Bitwise.shiftRightZfBy 1 v) (acc * 2 + Bitwise.and v 1)
    in
    go 0 x 0


{-| The number of `0 .. n-1` with bit `b` set.
-}
withBit : Int -> Int -> Int
withBit n b =
    let
        period =
            2 ^ (b + 1)

        half =
            2 ^ b
    in
    (n // period) * half + max 0 (modBy period n - half)


bench : Int -> Bool
bench n =
    let
        values =
            List.range 0 (n - 1)

        ( ones, zeros, reversedOk ) =
            List.foldl
                (\x ( o, z, ok ) -> ( o + popcount x, z + trailingZeros x, ok && reverse31 (reverse31 x) == x ))
                ( 0, 0, True )
                values
    in
    ones
        == List.sum (List.map (withBit n) (List.range 0 30))
        && zeros
        == (n - 1)
        - popcount (n - 1)
        && reversedOk
