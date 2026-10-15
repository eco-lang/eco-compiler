module NSieve exposing (bench, output)

{-| nsieve: count the primes below `10000 * 2^n`, `10000 * 2^(n-1)` and `10000 * 2^(n-2)` with
the sieve of Eratosthenes. The flags are a persistent `Array Bool`, so this measures `Array.set`.
-}

import Array exposing (Array)
import Output


clear : Int -> Int -> Int -> Array Bool -> Array Bool
clear step j m flags =
    if j >= m then
        flags

    else
        clear step (j + step) m (Array.set j False flags)


sieve : Int -> Int -> Int -> Array Bool -> Int
sieve i m count flags =
    if i >= m then
        count

    else if Array.get i flags == Just True then
        sieve (i + 1) m (count + 1) (clear i (i + i) m flags)

    else
        sieve (i + 1) m count flags


line : Int -> String
line m =
    "Primes up to "
        ++ String.padLeft 8 ' ' (String.fromInt m)
        ++ " "
        ++ String.padLeft 8 ' ' (String.fromInt (sieve 2 m 0 (Array.repeat m True)))
        ++ "\n"


{-| The benchmark's standard output: one line per sieve.
-}
output : Int -> String
output n =
    List.range 0 2
        |> List.map (\i -> line (10000 * 2 ^ (n - i)))
        |> String.concat


bench : Int -> Int
bench n =
    Output.checksum (output n)
