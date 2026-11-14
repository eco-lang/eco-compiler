module Tensor.Internal.Eval.Random exposing (normal, uniform)

{-| The evaluator (`Tensor.Eval`, which runs a graph in Elm rather than on MAX) needs random numbers
that come out the same whether the package runs under JavaScript or as native code with a 64-bit
`Int`, and this module is its generator.

It is counter-based: the value `uniform01` gives for a _counter_ j is computed from a hash of the
seed and j, not as the next state of a sequence. Nothing is carried from one value to the next, so
the value for counter j does not depend on how many values are drawn or in what order. The hash
works on 32-bit pieces. The seed is read as an unsigned 64-bit number (a negative `Int` through its
two's complement) and split into its two 32-bit _halves_. Each counter gives two 32-bit _draws_,
numbered 0 and 1, which `uniform01` combines into one value in [0, 1).

Giving the same bits on both platforms is why most of the file is 32-bit arithmetic written out by
hand. Under JavaScript an `Int` is a double, exact only below 2⁵³, and `Bitwise` works on signed
32-bit values. So the values passed between the steps of the hash are non-negative `Int`s below
2³², a product is formed from 16-bit pieces so that no partial product reaches 2⁴⁸, and
`Bitwise.xor` and the shifts in `shr32` are applied only to such values, on which 32-bit and 64-bit
operations give the same bits. Under JavaScript `Bitwise.xor` can still return a negative `Int`,
which `xor32` reads back as unsigned. The draws and `uniform01` are therefore the same on both
platforms for one seed `Int` and a counter j with |j| < 2⁵²: the hash forms the word 2j + d + 1
(described below) before reducing it, and that word is exact under JavaScript only for such j.
`uniform` and `normal` go on to floating-point arithmetic, and `normal` uses `logBase`, `sqrt` and
`cos`, whose last bits this module does not control.

Because the value for counter j depends only on the seed and j, lists drawn from one seed are
related. A shorter `uniform` list is a prefix of a longer one with the same range, two `uniform`
lists with different ranges are the same uniform values scaled and shifted, and element j of
`normal` is computed from the same uniform values as elements 2j and 2j + 1 of `uniform`. Inside the
hash, counter j and draw d make the word 2j + d + 1, which is reduced modulo 2³², so counters j and
j + 2³¹ give the same value: a `uniform` list repeats after 2³¹ elements and a `normal` list after
2³⁰.

This generator is the evaluator's own; MAX draws with its own random operations.

-}

import Bitwise


{-| The number of unsigned 32-bit values: the modulus by which `halves`, `draw` and `mul32` reduce.
-}
two32 : Int
two32 =
    4294967296


{-| Returns a · b modulo 2³², for `a` and `b` in 0 .. 2³² − 1.

`a` is split into 16-bit halves and each is multiplied by `b` separately, so no partial product
reaches 2⁴⁸ and every step is exact under JavaScript.

-}
mul32 : Int -> Int -> Int
mul32 a b =
    modBy two32 (modBy 65536 a * b + modBy 65536 ((a // 65536) * b) * 65536)


{-| Returns the bitwise exclusive or of two unsigned 32-bit values, as an unsigned value.

Under JavaScript `Bitwise.xor` gives a signed 32-bit result; the zero-fill shift by 0 reads it back
as unsigned.

-}
xor32 : Int -> Int -> Int
xor32 a b =
    Bitwise.shiftRightZfBy 0 (Bitwise.xor a b)


{-| Returns the unsigned 32-bit value `a` shifted right by `k` bits, with zeros shifted in.
-}
shr32 : Int -> Int -> Int
shr32 a k =
    Bitwise.shiftRightZfBy k a


{-| Returns an unsigned 32-bit value scrambled by MurmurHash3's 32-bit finaliser, `fmix32`.

It is a bijection on 32-bit values: each step is a right shift xored in, or a multiplication by an
odd constant modulo 2³², and both can be undone.

-}
fmix32 : Int -> Int
fmix32 h0 =
    let
        h1 =
            mul32 (xor32 h0 (shr32 h0 16)) 2246822507

        h2 =
            mul32 (xor32 h1 (shr32 h1 13)) 3266489909
    in
    xor32 h2 (shr32 h2 16)


{-| Returns the low and high unsigned 32-bit halves of the seed `s`, read as an unsigned 64-bit
value: a negative `s` gives the halves of its two's complement.
-}
halves : Int -> ( Int, Int )
halves s =
    let
        lo =
            modBy two32 s
    in
    ( lo, modBy two32 ((s - lo) // two32) )


{-| Returns draw `d` (0 or 1) of counter `j`, for a seed with halves `lo` and `hi`.

The counter and draw make the word 2j + d + 1, reduced modulo 2³², which is multiplied by
0x9E3779B1 (2654435761) modulo 2³², xored with `lo`, mixed by `fmix32`, xored with `hi` and mixed
again.

-}
draw : ( Int, Int ) -> Int -> Int -> Int
draw ( lo, hi ) j d =
    fmix32 (xor32 (fmix32 (xor32 lo (mul32 (modBy two32 (2 * j + d + 1)) 2654435761))) hi)


{-| Returns the uniform value in [0, 1) that counter `j` gives for `seed`.

It is a multiple of 2⁻⁵³: the 32 bits of draw 0 followed by the top 21 bits of draw 1, divided by
2⁵³.

-}
uniform01 : Int -> Int -> Float
uniform01 seed j =
    let
        hs =
            halves seed
    in
    (toFloat (draw hs j 0) * 2097152 + toFloat (shr32 (draw hs j 1) 11)) / 9007199254740992


{-| Returns `n` values, none when `n` ≤ 0, of which element j is low + u · (high − low) with u the
`uniform01` value of counter j.

The arithmetic rounds, so a value can equal `high`.

-}
uniform : Int -> Int -> Float -> Float -> List Float
uniform seed n low high =
    List.map (\j -> low + uniform01 seed j * (high - low)) (List.range 0 (n - 1))


{-| Returns `n` values, none when `n` ≤ 0, from the normal distribution with mean `mean` and
standard deviation `std`, by the Box–Muller transform.

Element j takes u1 = 1 − `uniform01` of counter 2j, which lies in (0, 1] so that its logarithm is
finite, and u2 = `uniform01` of counter 2j + 1, and is mean + std · √(−2 ln u1) · cos (2π u2). The
sine half of the transform, which would give a second value from the same pair, is not used.

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
