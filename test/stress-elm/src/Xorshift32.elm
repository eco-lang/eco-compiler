module Xorshift32 exposing (next)

{-| Deterministic 32-bit xorshift PRNG used by stress tests.

    Period is 2^32 - 1 with any non-zero seed. Suitable for stress testing
    encoder/decoder round-trips (reproducible failures) — NOT cryptographic.

-}

import Bitwise


next : Int -> Int
next s0 =
    let
        s1 =
            Bitwise.xor s0 (Bitwise.shiftLeftBy 13 s0)

        s2 =
            Bitwise.xor s1 (Bitwise.shiftRightZfBy 17 s1)

        s3 =
            Bitwise.xor s2 (Bitwise.shiftLeftBy 5 s2)
    in
    s3
