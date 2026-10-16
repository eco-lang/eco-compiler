module NSieveBits exposing (bench)

{-| nsieve-bits (Computer Language Shootout): the same three sieves as nsieve, counting the primes
below `10000 * 2^n`, `10000 * 2^(n-1)` and `10000 * 2^(n-2)`, but with the flags packed 32 to an
`Int` in an `Array Int`: `Bitwise.and`, `or`, `complement` and `shiftLeftBy` on every access.

Only bits 0 to 31 of each word are ever read, so the result is the same whether `Bitwise` works
on 32 bits (as elm/core defines it) or on 64 (eco's native backend). The counts must match
`NSieve.known`, so `n` must be 2 to 14.

-}

import Array exposing (Array)
import Bitwise
import NSieve


isSet : Int -> Array Int -> Bool
isSet i words =
    Bitwise.and (Maybe.withDefault 0 (Array.get (i // 32) words)) (Bitwise.shiftLeftBy (modBy 32 i) 1) /= 0


clearBit : Int -> Array Int -> Array Int
clearBit i words =
    let
        w =
            i // 32
    in
    Array.set w (Bitwise.and (Maybe.withDefault 0 (Array.get w words)) (Bitwise.complement (Bitwise.shiftLeftBy (modBy 32 i) 1))) words


clear : Int -> Int -> Int -> Array Int -> Array Int
clear step j m words =
    if j >= m then
        words

    else
        clear step (j + step) m (clearBit j words)


sieve : Int -> Int -> Int -> Array Int -> Int
sieve i m count words =
    if i >= m then
        count

    else if isSet i words then
        sieve (i + 1) m (count + 1) (clear i (i + i) m words)

    else
        sieve (i + 1) m count words


primes : Int -> Int
primes m =
    sieve 2 m 0 (Array.repeat (m // 32 + 1) -1)


bench : Int -> Bool
bench n =
    let
        sizes =
            List.map (\i -> 10000 * 2 ^ (n - i)) (List.range 0 2)

        expected =
            List.map (\k -> List.head (List.drop k NSieve.known) |> Maybe.withDefault -1) [ n, n - 1, n - 2 ]
    in
    n >= 2 && n <= 14 && List.map primes sizes == expected
