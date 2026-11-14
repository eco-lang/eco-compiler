module Tensor.Internal.Eval.Math exposing
    ( atanh
    , erf
    , exp
    , expm1
    , floorF
    , gelu
    , geluTanh
    , log
    , log1p
    , roundEven
    , sigmoid
    , silu
    , tanh
    , truncF
    )

{-| The evaluator needs functions on floats that `Basics` does not provide, and this module supplies
them, computed in f64.

`Basics` has no `exp`, no hyperbolic functions and no `erf`, only `logBase` for logarithms, and its
`floor`, `ceiling`, `round` and `truncate` return an `Int`. Here are `exp`, `log` (the natural
logarithm), `expm1`, `log1p`, `tanh`, `atanh` and `erf`; the activation functions built from them,
`sigmoid`, `silu`, `gelu` and `geluTanh`; and `floorF`, `truncF` and `roundEven`, which round to a
whole number and return it as a `Float`. Each of them gives NaN for NaN.

Two concerns shape the code. The first is accuracy. The direct formulas lose digits: `e ^ x` raises
an `e` that is already rounded, so its relative error grows with |x|; for a small x, `exp x - 1`
cancels most of its digits, and `log (1 + x)` loses those that the addition rounds away. So `exp`
raises `e` only to a small remainder, `expm1` and `log1p` use Kahan's corrections, and `tanh` and
`atanh` are written in terms of those two so that they stay accurate near 0. The longest function
by far is `erf`, which is W. J. Cody's rational approximations, one for each of three ranges of |x|.

The second is that an `Int` cannot hold NaN or ±∞, nor natively, where an `Int` has 64 bits, any
whole float outside −2⁶³ to 2⁶³ − 1. Every float of magnitude 2⁵² or more is already
a whole number, so the rounding functions return those unchanged and pass only smaller values
through `Int`, which holds them exactly both under JavaScript and natively. `Basics.truncate` is
not used, because under JavaScript it goes through a 32-bit integer. An `Int` has no −0, so a zero
result is given the sign of x, as IEEE rounding gives it.

-}


{-| The leading 32 significant bits of ln 2. The rest of its bits are zero, so its product with any
whole number `exp` multiplies it by is exact.
-}
ln2Hi : Float
ln2Hi =
    6.931471803691238e-1


{-| The part of ln 2 that `ln2Hi` leaves out: `ln2Hi + ln2Lo` is ln 2 to about 26 significant
digits.
-}
ln2Lo : Float
ln2Lo =
    1.9082149292705877e-10


{-| Returns eˣ. Above 709.8 it returns +∞ and below −745.2 it returns 0, which is what the f64
result rounds to there.

x is split as n · ln 2 + r, with n a whole number and |r| at most about ln 2 / 2, so that `e` is
raised only to r. Taking ln 2 in two parts, `ln2Hi` and `ln2Lo`, keeps r accurate (Cody and Waite's
reduction). The result e^r · 2ⁿ is scaled by 2ⁿ in two halves, because near the ends of the range
2ⁿ alone would overflow or underflow although the product does not.

-}
exp : Float -> Float
exp x =
    if isNaN x then
        x

    else if x > 709.8 then
        1 / 0

    else if x < -745.2 then
        0

    else
        let
            n =
                Basics.round (x / ln2Hi)

            r =
                (x - toFloat n * ln2Hi) - toFloat n * ln2Lo

            h =
                n // 2
        in
        (Basics.e ^ r) * (2 ^ toFloat h) * (2 ^ toFloat (n - h))


{-| Returns the natural logarithm of x.
-}
log : Float -> Float
log =
    logBase Basics.e


{-| Returns eˣ − 1, keeping its accuracy for x near 0, where `exp x - 1` would cancel most of
its digits.

With u = eˣ as computed, the result is (u − 1) · x / ln u, which is Kahan's correction: the error
in u is divided out again. When u is exactly 1 the result is x itself, when u − 1 rounds to −1 it
is −1, and when u is +∞ it is +∞.

-}
expm1 : Float -> Float
expm1 x =
    let
        u =
            exp x
    in
    if u == 1 then
        x

    else if isInfinite u then
        u

    else
        let
            um1 =
                u - 1
        in
        if um1 == -1 then
            -1

        else
            um1 * x / log u


{-| Returns ln (1 + x), keeping its accuracy for x near 0, where `log (1 + x)` would lose the
digits of x that the addition rounds away.

With u = 1 + x as computed, the result is ln u · x / (u − 1), which is Kahan's correction: dividing
by the u − 1 that was actually represented undoes the rounding of the addition. When u is exactly 1
the result is x itself, and when u is 0 or infinite it is ln u.

-}
log1p : Float -> Float
log1p x =
    let
        u =
            1 + x
    in
    if u == 1 then
        x

    else if isInfinite u || u == 0 then
        log u

    else
        log u * x / (u - 1)


{-| Returns the hyperbolic tangent of x, computed from `expm1 (2 * x)` so that it stays accurate
near 0.

Above 20 it returns 1 and below −20 it returns −1, which is what the f64 result rounds to there; for
large positive x the formula itself would give ∞ / ∞. A zero keeps its sign.

-}
tanh : Float -> Float
tanh x =
    if isNaN x then
        x

    else if x > 20 then
        1

    else if x < -20 then
        -1

    else if x == 0 then
        x

    else
        let
            e2 =
                expm1 (2 * x)
        in
        e2 / (e2 + 2)


{-| Returns the inverse hyperbolic tangent of x, ½ ln ((1 + x) / (1 − x)), computed as
½ `log1p` (2x / (1 − x)) so that it stays accurate near 0. 1 gives +∞ and −1 gives −∞.
-}
atanh : Float -> Float
atanh x =
    0.5 * log1p (2 * x / (1 - x))


{-| Returns the logistic function of x, 1 / (1 + e⁻ˣ).

It is computed as 1 / (1 + e⁻ˣ) for x ≥ 0 and as eˣ / (1 + eˣ) below, so that `exp` is only ever
given a number that is not positive and never overflows.

-}
sigmoid : Float -> Float
sigmoid x =
    if x >= 0 then
        1 / (1 + exp -x)

    else
        let
            e =
                exp x
        in
        e / (1 + e)


{-| Returns x · `sigmoid` x.
-}
silu : Float -> Float
silu x =
    x * sigmoid x


{-| Returns the GELU activation of x in its exact form, ½ x (1 + erf (x / √2)): x times the
probability that a standard normal variable is at most x.
-}
gelu : Float -> Float
gelu x =
    0.5 * x * (1 + erf (x / sqrt 2))


{-| Returns the GELU activation of x by its tanh approximation,
½ x (1 + tanh (√(2/π) (x + 0.044715 x³))).
-}
geluTanh : Float -> Float
geluTanh x =
    0.5 * x * (1 + tanh (sqrt (2 / pi) * (x + 0.044715 * x * x * x)))



-- ERF


{-| Returns the error function of x, by W. J. Cody's rational approximations in three ranges of |x|.

Up to 0.46875 one approximation gives erf itself. Above that, one approximation up to 4 and another
beyond give the complement erfc |x| = 1 − erf |x|, and the result is 1 − erfc |x| with the sign of
x. From 26.543 up erfc is taken as 0, so the result is ±1, and ±∞ gives ±1.

-}
erf : Float -> Float
erf x =
    let
        y =
            Basics.abs x
    in
    if isNaN x then
        x

    else if y <= 0.46875 then
        let
            ysq =
                if y > 1.11e-16 then
                    y * y

                else
                    0

            num =
                List.foldl (\a acc -> (acc + a) * ysq) (1.8577770618460315e-1 * ysq) [ 3.1611237438705655, 113.86415415105016, 377.485237685302 ]

            den =
                List.foldl (\b acc -> (acc + b) * ysq) ysq [ 23.601290952344122, 244.02463793444417, 1282.6165260773723 ]
        in
        x * (num + 3209.3775891384694) / (den + 2844.236833439171)

    else
        let
            erfc =
                if y <= 4 then
                    let
                        num =
                            List.foldl (\c acc -> (acc + c) * y)
                                (2.1531153547440383e-8 * y)
                                [ 0.5641884969886701, 8.883149794388377, 66.11919063714163, 298.6351381974001, 881.952221241769, 1712.0476126340707, 2051.0783778260716 ]

                        den =
                            List.foldl (\d acc -> (acc + d) * y)
                                y
                                [ 15.744926110709835, 117.6939508913125, 537.1811018620099, 1621.3895745666903, 3290.7992357334597, 4362.619090143247, 3439.3676741437216 ]
                    in
                    tail y ((num + 1230.3393547979972) / (den + 1230.3393548037495))

                else if y >= 26.543 then
                    0

                else
                    let
                        ysq =
                            1 / (y * y)

                        num =
                            List.foldl (\p acc -> (acc + p) * ysq)
                                (1.6315387137302097e-2 * ysq)
                                [ 0.30532663496123236, 0.36034489994980445, 0.12578172611122926, 1.6083785148742275e-2 ]

                        den =
                            List.foldl (\q acc -> (acc + q) * ysq)
                                ysq
                                [ 2.568520192289822, 1.8729528499234673, 0.5279051029514285, 6.051834131244132e-2 ]

                        r =
                            ysq * (num + 6.587491615298378e-4) / (den + 2.3352049762686918e-3)
                    in
                    tail y ((0.5641895835477563 - r) / y)

            v =
                (0.5 - erfc) + 0.5
        in
        if x < 0 then
            -v

        else
            v


{-| Returns e^(−y²) · r, which `erf` takes as erfc y for y above 0.46875, with r computed from its
rational approximations.

y² is not formed directly. With s = y rounded down to a multiple of 1/16, it is split as
s² + (y − s)(y + s); for the y that `erf` passes, s² is exact, so the rounding of y² never reaches
the exponent.

-}
tail : Float -> Float -> Float
tail y r =
    let
        ysq =
            floorF (y * 16) / 16

        del =
            (y - ysq) * (y + ysq)
    in
    exp (-ysq * ysq) * exp -del * r



-- WHOLE NUMBERS


{-| Returns ⌊x⌋, the greatest whole number not above x, as a `Float`. NaN, ±∞ and every x of
magnitude 2⁵² or more are returned unchanged. −0 gives −0.
-}
floorF : Float -> Float
floorF x =
    if isNaN x || isInfinite x || Basics.abs x >= 4503599627370496 then
        x

    else
        signedZero x (toFloat (Basics.floor x))


{-| Returns `r`, a whole number rounded from `x`, except that a zero `r` takes the sign of `x`:
x · 0 is −0 for a negative or −0 `x`, and +0 otherwise.
-}
signedZero : Float -> Float -> Float
signedZero x r =
    if r == 0 then
        x * 0

    else
        r


{-| Returns x with its fractional part dropped, rounding toward zero, as a `Float`. NaN, ±∞ and
every x of magnitude 2⁵² or more are returned unchanged. A zero result has the sign of x, so −0 and
an x between −1 and 0 give −0.
-}
truncF : Float -> Float
truncF x =
    if isNaN x || isInfinite x || Basics.abs x >= 4503599627370496 then
        x

    else if x >= 0 then
        signedZero x (toFloat (Basics.floor x))

    else
        signedZero x (toFloat (Basics.ceiling x))


{-| Returns x rounded to the nearest whole number, as a `Float`, with a value exactly halfway
going to the even neighbour: 0.5 gives 0, 1.5 and 2.5 give 2. NaN, ±∞ and every x of magnitude 2⁵²
or more are returned unchanged. A zero result has the sign of x, so −0 and an x from −0.5 up to
zero give −0.
-}
roundEven : Float -> Float
roundEven x =
    if isNaN x || isInfinite x || Basics.abs x >= 4503599627370496 then
        x

    else
        let
            f =
                floorF x

            d =
                x - f

            r =
                if d < 0.5 then
                    f

                else if d > 0.5 then
                    f + 1

                else if floorF (f / 2) * 2 == f then
                    f

                else
                    f + 1
        in
        signedZero x r
