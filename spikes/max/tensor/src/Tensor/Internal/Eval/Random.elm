module Tensor.Internal.Eval.Random exposing (normal, uniform, uniform01)

{-| The evaluator's counter-based generator. Every operation is exact on JavaScript and on eco:
32-bit values as non-negative `Int`s, products kept below 2⁴⁸, `Bitwise` only on values below 2³².
So the same seed and shape give the same draws under Node and on native code. (They differ from
MAX's: tests compare statistics.)

Draw d (0 or 1) of counter j, for the u64 seed with halves lo and hi:
`fmix32 (fmix32 (lo xor (2j + d + 1) · 0x9E3779B1) xor hi)`, where `fmix32` is MurmurHash3's
finaliser. A uniform in [0, 1) takes 53 bits from the two draws of one counter.

-}

import Bitwise


two32 : Int
two32 =
    4294967296


mul32 : Int -> Int -> Int
mul32 a b =
    modBy two32 (modBy 65536 a * b + modBy 65536 ((a // 65536) * b) * 65536)


xor32 : Int -> Int -> Int
xor32 a b =
    Bitwise.shiftRightZfBy 0 (Bitwise.xor a b)


shr32 : Int -> Int -> Int
shr32 a k =
    Bitwise.shiftRightZfBy k a


fmix32 : Int -> Int
fmix32 h0 =
    let
        h1 =
            mul32 (xor32 h0 (shr32 h0 16)) 2246822507

        h2 =
            mul32 (xor32 h1 (shr32 h1 13)) 3266489909
    in
    xor32 h2 (shr32 h2 16)


{-| The seed's two unsigned 32-bit halves.
-}
halves : Int -> ( Int, Int )
halves s =
    let
        lo =
            modBy two32 s
    in
    ( lo, modBy two32 ((s - lo) // two32) )


draw : ( Int, Int ) -> Int -> Int -> Int
draw ( lo, hi ) j d =
    fmix32 (xor32 (fmix32 (xor32 lo (mul32 (modBy two32 (2 * j + d + 1)) 2654435761))) hi)


{-| Counter j's uniform in [0, 1), 53 bits.
-}
uniform01 : Int -> Int -> Float
uniform01 seed j =
    let
        hs =
            halves seed
    in
    (toFloat (draw hs j 0) * 2097152 + toFloat (shr32 (draw hs j 1) 11)) / 9007199254740992


{-| n draws uniform in [low, high).
-}
uniform : Int -> Int -> Float -> Float -> List Float
uniform seed n low high =
    List.map (\j -> low + uniform01 seed j * (high - low)) (List.range 0 (n - 1))


{-| n normal draws (Box–Muller: element j from counters 2j and 2j + 1).
-}
normal : Int -> Int -> Float -> Float -> List Float
normal seed n mean std =
    List.map
        (\j ->
            let
                u1 =
                    1 - uniform01 seed (2 * j)

                u2 =
                    uniform01 seed (2 * j + 1)
            in
            mean + std * sqrt (-2 * logBase Basics.e u1) * cos (2 * pi * u2)
        )
        (List.range 0 (n - 1))
