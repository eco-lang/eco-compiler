module NSieve exposing (bench, known, output)

{-| nsieve: count the primes below `10000 * 2^n`, `10000 * 2^(n-1)` and `10000 * 2^(n-2)` with
the sieve of Eratosthenes. The flags are a persistent `Array Bool`, so this measures `Array.set`.

The three counts must match `known`, the number of primes below `10000 * 2^k` for `k` from 0 to
14 (computed with a separate sieve in Python), so `n` must be 2 to 14.
-}

import Array exposing (Array)


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


{-| The three sieve sizes, largest first.
-}
sizes : Int -> List Int
sizes n =
    List.map (\i -> 10000 * 2 ^ (n - i)) (List.range 0 2)


primes : Int -> Int
primes m =
    sieve 2 m 0 (Array.repeat m True)


{-| The benchmark's standard output: one line per sieve.
-}
output : Int -> String
output n =
    sizes n
        |> List.map (\m -> "Primes up to " ++ String.padLeft 8 ' ' (String.fromInt m) ++ " " ++ String.padLeft 8 ' ' (String.fromInt (primes m)) ++ "\n")
        |> String.concat


{-| The number of primes below `10000 * 2^k`, for `k` from 0 to 14.
-}
known : List Int
known =
    [ 1229, 2262, 4203, 7837, 14683, 27608, 52074, 98610, 187134, 356244, 679461, 1299069, 2488465, 4774995, 9177688 ]


bench : Int -> Bool
bench n =
    n >= 2 && n <= 14 && List.map primes (sizes n) == List.map (\k -> List.head (List.drop k known) |> Maybe.withDefault -1) [ n, n - 1, n - 2 ]
