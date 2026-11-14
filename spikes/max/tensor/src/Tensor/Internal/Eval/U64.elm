module Tensor.Internal.Eval.U64 exposing
    ( add, sub, mul, sum, dot, mean, wrap
    , compareU, modU, toFloatU, fromFloatU, two64
    , mulLow32
    )

{-| 64-bit integer arithmetic for the evaluator's `si64` and `ui64` elements, which are held in
`Int`s, written so that it gives the same answer under JavaScript as natively.

A `ui64` element is held as the `Int` with the same 64 bits, as `Tensor.Internal.Values` describes,
so values from 2⁶³ up are negative `Int`s. Addition, subtraction and multiplication give the same
bits whether those bits are read as signed or unsigned, but ordering, remainder, means and
conversion to and from `Float` do not; `compareU`, `modU`, `mean` with `unsigned` set, `toFloatU`
and `fromFloatU` read the bits as unsigned.

Natively an `Int` has 64 bits, and arithmetic on it wraps modulo 2⁶⁴ as an `si64` or `ui64` element
does. Under JavaScript an `Int` is a double: it holds every integer only up to 2⁵³, and `//` and
`Bitwise` work on 32 bits. So the functions here split a value into its two 32-bit _halves_, each a
non-negative `Int` below 2³², and work on those or on 16-bit pieces of them, where no intermediate
value reaches 2⁵³. The answer is the exact 64-bit value, wrapped modulo 2⁶⁴ into −2⁶³ … 2⁶³ − 1.
Natively that value is always an `Int`. Under JavaScript a value past 2⁵³ in magnitude may have no
exact `Int`, and then `add`, `sub`, `mul`, `sum`, `dot` and `mean` return `Nothing` rather than a
rounded value. Where the operands are small enough that plain `Int` arithmetic is exact on both
platforms, they use it.

Each operand must be an `Int` holding a whole number. One outside −2⁶³ … 2⁶³ − 1, which only
JavaScript can hold, is read modulo 2⁶⁴.

2⁶³ and 2⁶⁴ are computed with `^` rather than written as literals, so that no integer literal in
this module exceeds 2⁵³.


# Wrapping arithmetic

@docs add, sub, mul, sum, dot, mean, wrap


# Unsigned

@docs compareU, modU, toFloatU, fromFloatU, two64


# 32 bits

@docs mulLow32

-}

import Bitwise


{-| 2³², the modulus of a half.
-}
two32 : Int
two32 =
    4294967296


{-| 2³¹: a high half at or above it belongs to a negative `Int`.
-}
two31 : Int
two31 =
    2147483648


{-| 2⁵² as a `Float`: the bound on the magnitudes below which plain `Int` arithmetic is used, since
it is then exact on both platforms.
-}
plainBound : Float
plainBound =
    4503599627370496


{-| A 64-bit value as its high and low halves, in that order, each in 0 … 2³² − 1.
-}
type alias W =
    ( Int, Int )


{-| Returns the halves of `n` read modulo 2⁶⁴; a negative `n` gives those of its two's complement.

Under JavaScript `//` truncates its quotient to 32 bits. The quotient here is a whole number, and
truncating it keeps its value modulo 2³², which is all `modBy` keeps anyway.

-}
halves : Int -> W
halves n =
    let
        lo =
            modBy two32 n
    in
    ( modBy two32 ((n - lo) // two32), lo )


{-| Returns the `Int` in −2⁶³ … 2⁶³ − 1 whose halves are `w`. Under JavaScript, a value with no
exact `Int` comes back rounded.
-}
unchecked : W -> Int
unchecked ( hi, lo ) =
    (if hi >= two31 then
        hi - two32

     else
        hi
    )
        * two32
        + lo


{-| Returns the `Int` whose halves are `w`, or `Nothing` when no `Int` holds that value exactly,
which happens only under JavaScript.
-}
toInt : W -> Maybe Int
toInt w =
    let
        n =
            unchecked w
    in
    if halves n == w then
        Just n

    else
        Nothing


{-| Returns the sum of two values modulo 2⁶⁴.
-}
addW : W -> W -> W
addW ( ah, al ) ( bh, bl ) =
    let
        l =
            al + bl
    in
    ( modBy two32 (ah + bh + l // two32), modBy two32 l )


{-| Returns the difference of two values modulo 2⁶⁴.
-}
subW : W -> W -> W
subW ( ah, al ) ( bh, bl ) =
    let
        l =
            al - bl

        borrow =
            if l < 0 then
                1

            else
                0
    in
    ( modBy two32 (ah - bh - borrow), modBy two32 l )


{-| Returns minus a value, modulo 2⁶⁴.
-}
negW : W -> W
negW =
    subW ( 0, 0 )


{-| Returns the product of two values modulo 2⁶⁴, computed from 16-bit pieces: each partial
product is below 2³², and each column sum, carry included, below 2³⁵.
-}
mulW : W -> W -> W
mulW ( ah, al ) ( bh, bl ) =
    let
        ( a0, a1 ) =
            ( modBy 65536 al, al // 65536 )

        ( a2, a3 ) =
            ( modBy 65536 ah, ah // 65536 )

        ( b0, b1 ) =
            ( modBy 65536 bl, bl // 65536 )

        ( b2, b3 ) =
            ( modBy 65536 bh, bh // 65536 )

        c0 =
            a0 * b0

        c1 =
            a0 * b1 + a1 * b0 + c0 // 65536

        c2 =
            a0 * b2 + a1 * b1 + a2 * b0 + c1 // 65536

        c3 =
            a0 * b3 + a1 * b2 + a2 * b1 + a3 * b0 + c2 // 65536
    in
    ( modBy 65536 c3 * 65536 + modBy 65536 c2, modBy 65536 c1 * 65536 + modBy 65536 c0 )


{-| Returns the quotient of `w`, read as unsigned, by `n`, rounded down, for 1 ≤ `n` ≤ 2³⁷. It is a
long division over 16-bit pieces: each partial dividend is below `n` · 2¹⁶ ≤ 2⁵³, and each digit of
the quotient below 2¹⁶.
-}
divSmallW : W -> Int -> W
divSmallW ( hi, lo ) n =
    let
        step d r =
            let
                x =
                    r * 65536 + d
            in
            ( x // n, modBy n x )

        ( q3, r3 ) =
            step (hi // 65536) 0

        ( q2, r2 ) =
            step (modBy 65536 hi) r3

        ( q1, r1 ) =
            step (lo // 65536) r2

        ( q0, _ ) =
            step (modBy 65536 lo) r1
    in
    ( q3 * 65536 + q2, q1 * 65536 + q0 )


{-| Returns `a + b` wrapped modulo 2⁶⁴, or `Nothing` when no `Int` holds it exactly.
-}
add : Int -> Int -> Maybe Int
add a b =
    if abs (toFloat a) + abs (toFloat b) < plainBound then
        Just (a + b)

    else
        toInt (addW (halves a) (halves b))


{-| Returns `a - b` wrapped modulo 2⁶⁴, or `Nothing` when no `Int` holds it exactly.
-}
sub : Int -> Int -> Maybe Int
sub a b =
    if abs (toFloat a) + abs (toFloat b) < plainBound then
        Just (a - b)

    else
        toInt (subW (halves a) (halves b))


{-| Returns `a · b` wrapped modulo 2⁶⁴, or `Nothing` when no `Int` holds it exactly.
-}
mul : Int -> Int -> Maybe Int
mul a b =
    if abs (toFloat a * toFloat b) < plainBound then
        Just (a * b)

    else
        toInt (mulW (halves a) (halves b))


{-| Returns the sum of `l` wrapped modulo 2⁶⁴, 0 for an empty list, or `Nothing` when no `Int`
holds it exactly. Only the sum is checked, not the running sums on the way to it.
-}
sum : List Int -> Maybe Int
sum l =
    if List.foldl (\v acc -> acc + abs (toFloat v)) 0 l < plainBound then
        Just (List.sum l)

    else
        toInt (List.foldl (\v acc -> addW (halves v) acc) ( 0, 0 ) l)


{-| Returns the sum of the products of the pairs in `l` wrapped modulo 2⁶⁴, 0 for an empty list,
or `Nothing` when no `Int` holds it exactly. Only the final sum is checked.
-}
dot : List ( Int, Int ) -> Maybe Int
dot l =
    if List.foldl (\( a, b ) acc -> acc + abs (toFloat a * toFloat b)) 0 l < plainBound then
        Just (List.foldl (\( a, b ) acc -> acc + a * b) 0 l)

    else
        toInt (List.foldl (\( a, b ) acc -> addW (mulW (halves a) (halves b)) acc) ( 0, 0 ) l)


{-| Returns the mean of `l`: its sum wrapped modulo 2⁶⁴, divided by its length and rounded toward
zero, or `Nothing` when no `Int` holds the mean exactly. An empty list gives 0.

With `unsigned` the wrapped sum is read as unsigned, as for `ui64`, and otherwise as signed, as for
`si64`. The length must not exceed 2³⁷.

-}
mean : Bool -> List Int -> Maybe Int
mean unsigned l =
    let
        n =
            max 1 (List.length l)

        ( hi, lo ) =
            List.foldl (\v acc -> addW (halves v) acc) ( 0, 0 ) l
    in
    if unsigned || hi < two31 then
        toInt (divSmallW ( hi, lo ) n)

    else
        toInt (negW (divSmallW (negW ( hi, lo )) n))


{-| Returns `n` wrapped modulo 2⁶⁴ into −2⁶³ … 2⁶³ − 1. Natively that is `n` itself. Under
JavaScript an `n` outside that range is a double holding a whole number, and the wrapped value is
then held exactly as well.
-}
wrap : Int -> Int
wrap n =
    if abs (toFloat n) <= plainBound then
        n

    else
        unchecked (halves n)


{-| Compares `a` and `b` as unsigned numbers. When their signs agree this is the signed order;
otherwise the negative one, which stands for 2⁶³ or more, is the larger.
-}
compareU : Int -> Int -> Order
compareU a b =
    if (a < 0) == (b < 0) then
        compare a b

    else if a < 0 then
        GT

    else
        LT


{-| The number 2⁶⁴ as a `Float`: one more than the largest u64 value, and so the exclusive upper
bound of the u64 range.
-}
two64 : Float
two64 =
    2 ^ 64


{-| Returns the unsigned number that the bits of `n` stand for, as a `Float`. Above 2⁵³ a `Float`
cannot hold every integer, so the result may be rounded.
-}
toFloatU : Int -> Float
toFloatU n =
    if n >= 0 then
        toFloat n

    else
        let
            ( hi, lo ) =
                halves n
        in
        toFloat hi * 4294967296 + toFloat lo


{-| Returns the `Int` whose bits, read as unsigned, are the number `x`.

`x` must be a whole number in [0, 2⁶⁴). Neither condition is checked, and a fraction is rounded.

-}
fromFloatU : Float -> Int
fromFloatU x =
    if x >= 2 ^ 63 then
        round (x - two64)

    else
        round x


{-| Returns the remainder of `a` divided by `b`, both read as unsigned numbers. `b` must not be 0:
this is not checked, and `a` is then returned.

When `a` is not negative and `b` is positive this is `modBy`. Otherwise it is a long division over
the 64 bits of `a`, from the top bit down, on halves: each step shifts one bit of `a` into the
running remainder and subtracts `b` when the remainder reaches it. The remainder is below `b`, so
an `Int` holds it exactly on both platforms.

-}
modU : Int -> Int -> Int
modU a b =
    if a >= 0 && b > 0 then
        modBy b a

    else
        let
            ( ah, al ) =
                halves a

            bw =
                halves b

            -- ah and al are below 2³², where 32-bit and 64-bit shifts agree
            bitOf i =
                if i >= 32 then
                    Bitwise.and 1 (Bitwise.shiftRightZfBy (i - 32) ah)

                else
                    Bitwise.and 1 (Bitwise.shiftRightZfBy i al)

            step i ( rh, rl ) =
                let
                    -- r < b, so 2r + bit < 2b; when r's top bit is set, 2r + bit ≥ 2⁶⁴ > b,
                    -- and subtracting b wraps back below 2⁶⁴
                    overflow =
                        rh >= two31

                    r2 =
                        ( modBy two32 (rh * 2 + rl // two31), modBy two32 (rl * 2 + bitOf i) )
                in
                if overflow || compare r2 bw /= LT then
                    subW r2 bw

                else
                    r2
        in
        unchecked (List.foldl step ( 0, 0 ) (List.range 0 63 |> List.reverse))


{-| Returns `a · b` modulo 2³², in 0 … 2³² − 1, exactly on both platforms: both are reduced modulo
2³² and `a` is split into 16-bit halves, so no partial product reaches 2⁴⁹.
-}
mulLow32 : Int -> Int -> Int
mulLow32 a b =
    let
        x =
            modBy two32 a

        y =
            modBy two32 b
    in
    modBy two32 (modBy 65536 x * y + modBy 65536 ((x // 65536) * y) * 65536)
