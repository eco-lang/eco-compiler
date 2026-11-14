module Tensor.Internal.Values exposing
    ( Values(..)
    , altHash
    , decimalText
    , fitsDtype
    , forDtype
    , length
    , limbs
    , u64Text
    )

{-| A `Float` holds every integer exactly only up to 2⁵³, and an integer tensor's elements can
be 64 bits wide, so this module keeps a tensor's element values in the Elm type that holds them
exactly.

That type is fixed by the dtype's _kind_: `Float` for the floating-point dtypes, and `Int` for the
integer dtypes and for `bool`, whose elements are 0 and 1. A `Values` is a list of one or the
other. Held as `Int`s, integers are exact to 64 bits in native code. Under JavaScript an `Int` is a
double, which holds every integer exactly only up to 2⁵³, whatever this module does. `forDtype`
turns float values into integer values by rounding, so integers that arrive through it have passed
through `Float`.

A `ui64` element follows the _u64 convention_: it is the `Int` with the same 64 bits, so the
values 2⁶³ … 2⁶⁴ − 1 are held as negative `Int`s. `u64Text` writes such an element in unsigned
decimal, and `decimalText` writes an `Int` in signed decimal.

An `Int` in −2⁶³ … 2⁶³ − 1 that JavaScript holds exactly (every integer within ±2⁵³, and beyond
that those that are doubles) gives the same limbs, text and hash here under JavaScript as in native
code. Under JavaScript `//` keeps only 32 bits of its quotient and `String.fromInt` writes an
integer beyond 2⁵³ to only about 17 significant digits, so neither is relied on for such an integer.

The rest of the module checks integer values against the ranges of `si8`, `ui8`, `si32` and
`bool` (`fitsDtype`) and gives a second hash of a constant's values (`altHash`), made without its
key (the hash that stands for an expression's identity; see `Tensor.Internal.Key`), from 16-bit
pieces of each element's bits (`limbs`, for an integer element).

-}

import Bytes exposing (Endianness(..))
import Bytes.Decode as Decode
import Bytes.Encode as Encode
import Tensor.Internal.Prim as P exposing (DT(..))


{-| A tensor's element values, as a list in the Elm type of its dtype's kind.

`FloatValues` holds the elements of a floating-point dtype. `IntValues` holds those of an integer
dtype, `ui64` elements under the u64 convention, and those of `bool`, as 0 and 1.

A `Values` does not record its dtype, and nothing here checks that the constructor matches the
dtype it is used with: `fitsDtype` gives `Nothing` for `FloatValues` whatever the dtype.

-}
type Values
    = FloatValues (List Float)
    | IntValues (List Int)


{-| Returns the number of elements.
-}
length : Values -> Int
length vs =
    case vs of
        FloatValues l ->
            List.length l

        IntValues l ->
            List.length l


{-| Returns the floats as the values of `dt`: kept as `FloatValues` for a floating-point dtype,
and otherwise, for the integer dtypes and `bool`, rounded with `round` to `IntValues`.

Nothing is checked. A value outside the dtype's range is kept as it rounds, and NaN or an infinity
is rounded too, giving no meaningful `Int` rather than an error.

-}
forDtype : DT -> List Float -> Values
forDtype dt l =
    if P.isFloat dt then
        FloatValues l

    else
        IntValues (List.map round l)


{-| Returns why the values do not fit `dt`, naming the first element in list order that is out of
range (`"value 300 does not fit ui8"`), or `Nothing` if every element fits.

Only `IntValues` for `si8`, `ui8`, `si32` and `bool` are checked, against −128 … 127, 0 … 255,
−2³¹ … 2³¹ − 1 and 0 … 1. A NaN element, which only JavaScript can hold as an `Int`, fits none of
them (`"value NaN does not fit si32"`). `si64` and `ui64` are not checked, and natively every `Int`
fits both (for `ui64` a negative `Int` is an element of 2⁶³ or more). `FloatValues` give `Nothing`
whatever `dt` is.

-}
fitsDtype : DT -> Values -> Maybe String
fitsDtype dt vs =
    case vs of
        FloatValues _ ->
            Nothing

        IntValues l ->
            let
                range =
                    case dt of
                        SI8 ->
                            Just ( -128, 127 )

                        UI8 ->
                            Just ( 0, 255 )

                        SI32 ->
                            Just ( -2147483648, 2147483647 )

                        Bool ->
                            Just ( 0, 1 )

                        _ ->
                            Nothing
            in
            case range of
                Just ( lo, hi ) ->
                    List.filter (\n -> n < lo || n > hi || n /= n) l
                        |> List.head
                        |> Maybe.map (\n -> "value " ++ String.fromInt n ++ " does not fit " ++ P.dtName dt)

                Nothing ->
                    Nothing


{-| Returns the 64-bit pattern of an `Int` as four 16-bit limbs, lowest first, so that `-1` gives
four 65535s and −2⁶³ gives `[0, 0, 0, 32768]`.

The limbs are the same under JavaScript and in native code for every `Int` in −2⁶³ … 2⁶³ − 1 that
JavaScript holds exactly. Under JavaScript an integral `Int` outside that range gives the limbs of
its value modulo 2⁶⁴, and NaN or an infinity gives `[NaN, NaN, NaN, NaN]`.

-}
limbs : Int -> List Int
limbs n0 =
    let
        step _ ( n, acc ) =
            let
                ( p, rest ) =
                    splitLimb n
            in
            ( rest, p :: acc )
    in
    List.foldl step ( n0, [] ) [ 1, 2, 3, 4 ]
        |> Tuple.second
        |> List.reverse


{-| Returns `n`'s lowest 16-bit limb, in 0 … 65535 even for a negative `n`, and the rest of `n`
above it, (`n` − limb) / 65536.

The quotient is taken with `//`, which gives it exactly in native code. Under JavaScript `//` keeps
only 32 bits of its quotient; when that quotient does not multiply back to `n` − limb, it is taken
from the `Float` division instead, which is exact there because `n` − limb is a double and 65536 a
power of two.

-}
splitLimb : Int -> ( Int, Int )
splitLimb n =
    let
        p =
            modBy 65536 n

        q =
            (n - p) // 65536
    in
    if q * 65536 == n - p then
        ( p, q )

    else
        ( p, round (toFloat (n - p) / 65536) )


{-| Returns the unsigned decimal text of an `Int`'s 64 bits, which is the value of a `ui64`
element under the u64 convention: a non-negative `Int` is written as it is, and a negative one as
itself plus 2⁶⁴, so `-1` gives `"18446744073709551615"`.

For an `Int` in −2⁶³ … 2⁶³ − 1 that JavaScript holds exactly, the text is the same under
JavaScript as in native code. Under JavaScript an integral `Int` outside that range is written
modulo 2⁶⁴, and NaN or an infinity gives `"NaN"`.

-}
u64Text : Int -> String
u64Text n =
    if n >= 0 && n <= 9007199254740992 then
        String.fromInt n

    else
        unsignedText (limbs n)


{-| Returns the signed decimal text of an `Int`, which in native code is what `String.fromInt`
writes, so that −2⁶³ gives `"-9223372036854775808"`.

For an `Int` in −2⁶³ … 2⁶³ − 1 that JavaScript holds exactly, the text is the same under
JavaScript as in native code; `String.fromInt` itself, under JavaScript, writes an integer beyond
2⁵³ to only about 17 significant digits. Under JavaScript an integral `Int` outside that range is
written as the signed value of its pattern modulo 2⁶⁴, and NaN or an infinity gives `"NaN"`.

-}
decimalText : Int -> String
decimalText n =
    if n >= -9007199254740992 && n <= 9007199254740992 then
        String.fromInt n

    else
        let
            ls =
                limbs n

            top =
                List.drop 3 ls |> List.head |> Maybe.withDefault 0
        in
        if List.any (\l -> l /= l) ls then
            "NaN"

        else if top < 32768 then
            unsignedText ls

        else
            "-" ++ unsignedText (negateLimbs ls)


{-| Returns the limbs, lowest first, of the two's-complement negation of the 64-bit pattern given by
`ls`, lowest first. The negation of −2⁶³'s limbs is the same limbs, which `unsignedText` reads as
2⁶³.
-}
negateLimbs : List Int -> List Int
negateLimbs ls =
    List.foldl
        (\l ( acc, carry ) ->
            let
                v =
                    65535 - l + carry
            in
            ( modBy 65536 v :: acc, v // 65536 )
        )
        ( [], 1 )
        ls
        |> Tuple.first
        |> List.reverse


{-| Returns the decimal text of the unsigned number whose 16-bit limbs, lowest first, are `ls`, or
`"0"` for limbs that are all 0.

The number is divided by ten a digit at a time, limb by limb from the highest, so every
intermediate value is below 655360 and exact under JavaScript too. A NaN limb gives `"NaN"`.

-}
unsignedText : List Int -> String
unsignedText ls =
    let
        divTen highFirst =
            List.foldl
                (\l ( acc, r ) ->
                    let
                        cur =
                            r * 65536 + l
                    in
                    ( cur // 10 :: acc, modBy 10 cur )
                )
                ( [], 0 )
                highFirst
                |> Tuple.mapFirst List.reverse

        go highFirst digits =
            if List.all ((==) 0) highFirst then
                digits

            else
                let
                    ( q, r ) =
                        divTen highFirst
                in
                go q (String.fromInt r ++ digits)
    in
    case go (List.reverse ls) "" of
        "" ->
            "0"

        text ->
            text


{-| Returns a second hash of the values, made without their key, for telling apart constants
whose keys collide.

It folds the kind (1 for `FloatValues`, 2 for `IntValues`), the element count and each element's
four 16-bit limbs (a float's taken from its 64-bit pattern) into a number in 0 … 2147483628 (under
JavaScript, NaN if an integer element is NaN or infinite), with a multiplier and modulus other
than those `Tensor.Internal.Key` mixes with. Values that differ in kind, count, order or any
element's bits usually hash differently, but this hash can collide too. Floats count by bit
pattern, so NaNs with different patterns, and `0.0` and `-0.0`, are different elements to it. An
integer in −2⁶³ … 2⁶³ − 1 that JavaScript holds exactly hashes the same under JavaScript as in
native code, since its `limbs` are the same.

-}
altHash : Values -> Int
altHash vs =
    let
        fold =
            List.foldl (\x h -> modBy 2147483629 (7919 * h + x))
    in
    case vs of
        FloatValues l ->
            List.foldl (\f h -> fold h (floatLimbs f)) (fold 0 [ 1, List.length l ]) l

        IntValues l ->
            List.foldl (\n h -> fold h (limbs n)) (fold 0 [ 2, List.length l ]) l


{-| Returns the 64-bit pattern of a float as four 16-bit limbs, lowest first, read from its
little-endian encoding. Unlike `limbs`, it is exact under JavaScript too, since each word it
divides is below 2³².

The `Nothing` branch is never taken: eight encoded bytes always decode as two 32-bit words.

-}
floatLimbs : Float -> List Int
floatLimbs f =
    case Decode.decode (Decode.map2 Tuple.pair (Decode.unsignedInt32 LE) (Decode.unsignedInt32 LE)) (Encode.encode (Encode.float64 LE f)) of
        Just ( a, b ) ->
            [ modBy 65536 a, a // 65536, modBy 65536 b, b // 65536 ]

        Nothing ->
            []
