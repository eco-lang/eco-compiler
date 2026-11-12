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

{-| The floating-point functions `Basics` lacks, in f64, as the evaluator computes them: a
range-reduced `exp`, Kahan's `expm1` and `log1p`, W. J. Cody's `erf`, and whole-number rounding that
never calls `Basics.floor`/`truncate`/`round` outside their safe range (under JavaScript `truncate`
is 32-bit; under eco `floor` of |x| ≥ 2⁶³ overflows).
-}


ln2Hi : Float
ln2Hi =
    6.931471803691238e-1


ln2Lo : Float
ln2Lo =
    1.9082149292705877e-10


{-| eˣ: x = n ln 2 + r with |r| ≤ ln 2 / 2 (Cody–Waite), e^r, then scaled by 2ⁿ in two halves so
subnormal and overflowing results come out right.
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


log : Float -> Float
log =
    logBase Basics.e


{-| eˣ − 1, accurate near 0 (Kahan).
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


{-| log (1 + x), accurate near 0 (Kahan).
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


atanh : Float -> Float
atanh x =
    0.5 * log1p (2 * x / (1 - x))


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


silu : Float -> Float
silu x =
    x * sigmoid x


gelu : Float -> Float
gelu x =
    0.5 * x * (1 + erf (x / sqrt 2))


geluTanh : Float -> Float
geluTanh x =
    0.5 * x * (1 + tanh (sqrt (2 / pi) * (x + 0.044715 * x * x * x)))



-- ERF


{-| The error function: W. J. Cody's rational Chebyshev approximations (Math. Comp. 1969, the
CALERF routine of SPECFUN), in three ranges of |x|.
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


{-| exp (−y²) times r, with y² split so its rounding error does not reach the result.
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


{-| ⌊x⌋ as a float; NaN, ±∞ and |x| ≥ 2⁵² (already whole) unchanged.
-}
floorF : Float -> Float
floorF x =
    if isNaN x || isInfinite x || Basics.abs x >= 4503599627370496 then
        x

    else
        toFloat (Basics.floor x)


truncF : Float -> Float
truncF x =
    if isNaN x || isInfinite x || Basics.abs x >= 4503599627370496 then
        x

    else if x >= 0 then
        toFloat (Basics.floor x)

    else
        toFloat (Basics.ceiling x)


{-| Rounding half to even, as MAX rounds.
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
        if r == 0 && x < 0 then
            0

        else
            r
