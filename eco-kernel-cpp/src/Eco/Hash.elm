module Eco.Hash exposing (stringWithSeed, string, string64)

{-| Allocation-free native string hashing, for Elm-side hash tables.

`Data.HashMap` takes the hash as an argument, so its speed is decided by the
hash the caller supplies. Computing one in Elm is much more expensive than it
looks: `String.foldl` snapshots the string into a C++ vector and then performs
one GENERIC CLOSURE DISPATCH per character, boxing and unboxing the
accumulator each time. Against a `Dict String` probe — whose comparisons bottom
out in a memcmp — that loses, and the compile-time loop measured it losing
three separate times before this module existed.

This computes the same hash in one C loop with no allocation, so the lowered
call is gc-leaf: no statepoint, and none of the caller's live pointers get
spilled around it.

The mix is

    h_0     = seed
    h_(i+1) = (h_i * 33 + (c_i mod 2^26) + 7) mod 2^26

over UTF-16 code units. Base 2^26 matches `Monomorphized.hashBase`: two of
these pack into 2^52, inside the exact-integer range of both the native i64
and the JS double, so the native, JS-bootstrap and pure-Elm implementations
agree bit for bit. A hash is only ever a bucket choice — `Data.HashMap`
resolves collisions with its own equality — so agreement is a portability
nicety, never a correctness requirement.

@docs stringWithSeed, string, string64

-}

import Eco.Kernel.Hash


{-| Mix `seed` over the string's code units.
-}
stringWithSeed : Int -> String -> Int
stringWithSeed seed s =
    Eco.Kernel.Hash.stringWithSeed seed s


{-| `stringWithSeed` at the conventional seed 23.
-}
string : String -> Int
string s =
    Eco.Kernel.Hash.stringWithSeed 23 s


{-| FNV-1a over the code units, full 64-bit and seeded.

For `Data.HashMap` BUCKET KEYS only. That map keys its buckets in a `Dict Int`
on the raw hash — no mask, no `modBy`, no `Bitwise` — so any `Int` is legal,
negatives included, and the extra width just means shorter buckets. It is also
cheaper than `stringWithSeed`: no modulo per character.

Do NOT use it where the result is PACKED with another hash
(`Monomorphized.packHashes` needs both halves inside `[0, 2^26)`); use
`stringWithSeed` there.

-}
string64 : Int -> String -> Int
string64 seed s =
    Eco.Kernel.Hash.string64 seed s
