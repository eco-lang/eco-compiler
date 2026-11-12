module Tensor.Internal.Eval.U64 exposing (compareU, fromFloatU, maxU, minU, modU, toFloatU, two64)

{-| u64 arithmetic on `Int`s that hold the 64 bits (2⁶³ … 2⁶⁴ − 1 are negative `Int`s): unsigned
comparison, remainder and conversion. Exact where `Int` is 64-bit (eco native code); under
JavaScript only below 2⁵³.

No integer literal here exceeds 2⁵³: eco's front end refuses them (it runs under Node).

-}

import Bitwise


{-| Unsigned order: if the signs agree, the signed order; otherwise the negative one (≥ 2⁶³) is larger.
-}
compareU : Int -> Int -> Order
compareU a b =
    if (a < 0) == (b < 0) then
        compare a b

    else if a < 0 then
        GT

    else
        LT


maxU : Int -> Int -> Int
maxU a b =
    if compareU a b == LT then
        b

    else
        a


minU : Int -> Int -> Int
minU a b =
    if compareU a b == GT then
        b

    else
        a


{-| 2⁶⁴ as a `Float`, built at run time.
-}
two64 : Float
two64 =
    2 ^ 64


{-| The unsigned value of the bits, as a `Float`.
-}
toFloatU : Int -> Float
toFloatU n =
    if n >= 0 then
        toFloat n

    else
        let
            lo =
                modBy 4294967296 n

            hi =
                modBy 4294967296 ((n - lo) // 4294967296)
        in
        toFloat hi * 4294967296 + toFloat lo


{-| A float in [0, 2⁶⁴), already whole, as the `Int` with its bits.
-}
fromFloatU : Float -> Int
fromFloatU x =
    if x >= 2 ^ 63 then
        round (x - two64)

    else
        round x


{-| `a` modulo `b`, both unsigned (b ≠ 0): shift-and-subtract long division over the 64 bits.
-}
modU : Int -> Int -> Int
modU a b =
    if a >= 0 && b > 0 then
        modBy b a

    else
        let
            step i r =
                let
                    bit =
                        Bitwise.and 1 (Bitwise.shiftRightZfBy i a)

                    -- r < b, so 2r + bit < 2b; when r's top bit is set, 2r overflows and is ≥ b
                    overflow =
                        r < 0

                    r2 =
                        Bitwise.or (Bitwise.shiftLeftBy 1 r) bit
                in
                if overflow || compareU r2 b /= LT then
                    r2 - b

                else
                    r2
        in
        List.foldl step 0 (List.range 0 63 |> List.reverse)
