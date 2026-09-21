module Eco.Hash exposing (stringWithSeed, string, string64)

{-| PURE TWIN of the kernel-backed `Eco.Hash`, for stock Elm: bootstrap stage 1
and the unit suite, which have no kernel.

`stringWithSeed` agrees with `eco/Hash.cpp` and `Eco/Kernel/Hash.js` bit for
bit, because its result is PACKED with another hash by
`Monomorphized.packHashes` and both halves must stay inside `[0, 2^26)`.

`string64` deliberately does NOT agree with the native kernel: JS and stock Elm
have no 64-bit integers. Nothing compares hashes across builds — `Data.HashMap`
never serializes one, and a hash only chooses a bucket, with `eq` deciding
matches — so each build need only be self-consistent.

@docs stringWithSeed, string, string64

-}

import Bitwise


{-| Mix `seed` over the string's code units, result in `[0, 2^26)`.
-}
stringWithSeed : Int -> String -> Int
stringWithSeed seed s =
    String.foldl (\c h -> modBy 67108864 (h * 33 + modBy 67108864 (Char.toCode c) + 7)) (modBy 67108864 seed) s


{-| `stringWithSeed` at the conventional seed 23.
-}
string : String -> Int
string s =
    stringWithSeed 23 s


{-| Wide variant, for `Data.HashMap` bucket keys only. 2^31 keeps every
intermediate exact under stock Elm.
-}
string64 : Int -> String -> Int
string64 seed s =
    String.foldl
        (\c h -> modBy 2147483648 (Bitwise.xor h (Char.toCode c) * 16777619))
        (modBy 2147483648 (Bitwise.xor seed 2166136261))
        s
