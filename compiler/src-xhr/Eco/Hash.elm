module Eco.Hash exposing (stringWithSeed, string, string64)

{-| The stock-Elm build has no kernel, so this module computes the compiler's
string hashes in plain Elm. It is the pure twin of the kernel-backed
`Eco.Hash`, with the same exposed names and signatures.

A string hash is an `Int` folded over the characters of a string, starting
from a seed. There are two kinds, and they make different promises.

The narrow hash, `stringWithSeed` and `string`, is always in `[0, 2^26)`. The
seed is reduced modulo 2^26, and each character then turns the hash `h` into
`h * 33 + c + 7` reduced modulo 2^26, where `c` is the character's code. No
intermediate reaches 2^32, so the arithmetic is exact. For a non-negative seed
and a string with no UTF-16 surrogate code units, the result is the one the
kernel implementations give. They step over UTF-16 code units, so a character
above U+FFFF is one step here and two there, and they can reduce a negative
seed to a negative starting value, where `modBy` here always gives a
non-negative one.

The wide hash, `string64`, is a different mix, and its value depends on the
build. Here it is in `[0, 2^31)`; the native kernel computes a 64-bit FNV-1a
hash and can return any `Int`, negatives included. Within one build the same
seed and string always give the same result, but neither its range nor its
value carries over to another build.

@docs stringWithSeed, string, string64

-}

import Bitwise


{-| Returns the narrow hash of `s` starting from `seed`. The result is in
`[0, 2^26)` whatever the seed.

The fold steps over `Char`s, which are code points, not UTF-16 code units.

-}
stringWithSeed : Int -> String -> Int
stringWithSeed seed s =
    String.foldl (\c h -> modBy 67108864 (h * 33 + modBy 67108864 (Char.toCode c) + 7)) (modBy 67108864 seed) s


{-| Returns the narrow hash of `s` at seed 23.
-}
string : String -> Int
string s =
    stringWithSeed 23 s


{-| Returns the wide hash of `s` starting from `seed`, which in this build is
in `[0, 2^31)`.

The starting value is `seed` xor 2166136261, reduced modulo 2^31. Each
character's code is then xored into the hash, and the hash multiplied by
16777619 and reduced modulo 2^31. That product can exceed 2^53, beyond which a
JavaScript number is not exact, so the result can differ from the true modular
arithmetic. It is still deterministic: the same `seed` and `s` give the same
result.

-}
string64 : Int -> String -> Int
string64 seed s =
    String.foldl
        (\c h -> modBy 2147483648 (Bitwise.xor h (Char.toCode c) * 16777619))
        (modBy 2147483648 (Bitwise.xor seed 2166136261))
        s
