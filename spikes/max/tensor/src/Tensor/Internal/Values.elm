module Tensor.Internal.Values exposing
    ( Values(..)
    , altHash
    , fitsDtype
    , forDtype
    , length
    , limbs
    , u64Text
    )

{-| A constant's element values, as the Elm type of its dtype's kind: `Float` for floating dtypes,
`Int` for integer dtypes and Bool (0 or 1). Integers never pass through `Float`, so they are exact
to 64 bits where `Int` is (eco native code).

A u64 element is the `Int` with the same 64 bits: 2⁶³ … 2⁶⁴ − 1 are negative `Int`s.

No integer literal here exceeds 2⁵³: eco's front end refuses such literals (it runs under Node).

-}

import Bytes exposing (Endianness(..))
import Bytes.Decode as Decode
import Bytes.Encode as Encode
import Tensor.Internal.Prim as P exposing (DT(..))


type Values
    = FloatValues (List Float)
    | IntValues (List Int)


length : Values -> Int
length vs =
    case vs of
        FloatValues l ->
            List.length l

        IntValues l ->
            List.length l


{-| Floats as the values of `dt`: rounded to `Int`s for integer dtypes and Bool, kept otherwise.
-}
forDtype : DT -> List Float -> Values
forDtype dt l =
    if P.isFloat dt then
        FloatValues l

    else
        IntValues (List.map round l)


{-| Why integer values do not fit `dt`, if they do not. i64 and u64 take every `Int`.
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
                    List.filter (\n -> n < lo || n > hi) l
                        |> List.head
                        |> Maybe.map (\n -> "value " ++ String.fromInt n ++ " does not fit " ++ P.dtName dt)

                Nothing ->
                    Nothing


{-| An `Int`'s 64 bits as four 16-bit limbs, low first: floored division, so exact for negative
values and for the most negative `Int` (no `abs` or `negate`).
-}
limbs : Int -> List Int
limbs n0 =
    let
        step _ ( n, acc ) =
            let
                p =
                    modBy 65536 n
            in
            ( (n - p) // 65536, p :: acc )
    in
    List.foldl step ( n0, [] ) [ 1, 2, 3, 4 ]
        |> Tuple.second
        |> List.reverse


{-| The unsigned decimal of an `Int`'s 64 bits (the u64 convention).
-}
u64Text : Int -> String
u64Text n =
    if n >= 0 then
        String.fromInt n

    else
        let
            lo0 =
                modBy 4294967296 n

            hi0 =
                modBy 4294967296 ((n - lo0) // 4294967296)

            go hi lo digits =
                if hi == 0 && lo == 0 then
                    digits

                else
                    let
                        t =
                            modBy 10 hi * 4294967296 + lo
                    in
                    go (hi // 10) (t // 10) (String.fromInt (modBy 10 t) ++ digits)
        in
        go hi0 lo0 ""


{-| A second hash of the values, independent of their structural key's (different multipliers), so
lowering can tell apart two different constants whose keys collide.
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


floatLimbs : Float -> List Int
floatLimbs f =
    case Decode.decode (Decode.map2 Tuple.pair (Decode.unsignedInt32 LE) (Decode.unsignedInt32 LE)) (Encode.encode (Encode.float64 LE f)) of
        Just ( a, b ) ->
            [ modBy 65536 a, a // 65536, modBy 65536 b, b // 65536 ]

        Nothing ->
            []
