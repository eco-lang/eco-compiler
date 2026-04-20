module Gen exposing
    ( Seed
    , asciiString
    , bool
    , char
    , float
    , float32Safe
    , int16
    , int32
    , int8
    , intIn
    , listOf
    , oneOfGen
    , pair
    , uint16
    , uint32
    , uint8
    , unicodeString
    )

{-| Generator combinators over a 32-bit xorshift state. Each generator has
    type `Seed -> (a, Seed)` so they compose without a monad.
-}

import Bitwise
import Xorshift32


type alias Seed =
    Int


{-| Uniform integer in [lo, hi] (inclusive on both ends).
    Assumes hi >= lo and range fits in a positive Int.
-}
intIn : Int -> Int -> Seed -> ( Int, Seed )
intIn lo hi seed =
    let
        s =
            Xorshift32.next seed

        u =
            Bitwise.shiftRightZfBy 0 s

        range =
            hi - lo + 1
    in
    ( lo + modBy range u, s )


int8 : Seed -> ( Int, Seed )
int8 =
    intIn -128 127


int16 : Seed -> ( Int, Seed )
int16 =
    intIn -32768 32767


int32 : Seed -> ( Int, Seed )
int32 seed =
    let
        ( lo, s1 ) =
            intIn 0 65535 seed

        ( hi, s2 ) =
            intIn 0 65535 s1

        unsigned =
            hi * 65536 + lo
    in
    ( if unsigned >= 2147483648 then
        unsigned - 4294967296

      else
        unsigned
    , s2
    )


uint8 : Seed -> ( Int, Seed )
uint8 =
    intIn 0 255


uint16 : Seed -> ( Int, Seed )
uint16 =
    intIn 0 65535


uint32 : Seed -> ( Int, Seed )
uint32 seed =
    let
        ( lo, s1 ) =
            intIn 0 65535 seed

        ( hi, s2 ) =
            intIn 0 65535 s1
    in
    ( hi * 65536 + lo, s2 )


bool : Seed -> ( Bool, Seed )
bool seed =
    let
        ( n, s ) =
            intIn 0 1 seed
    in
    ( n == 1, s )


{-| Finite Float across a wide but safe range.
    Never produces NaN / Infinity so roundtrips are well-defined.
-}
float : Seed -> ( Float, Seed )
float seed =
    let
        ( sign, s1 ) =
            intIn 0 1 seed

        ( whole, s2 ) =
            intIn 0 1000000 s1

        ( frac, s3 ) =
            intIn 0 999999 s2

        v =
            toFloat whole + toFloat frac / 1000000.0

        signed =
            if sign == 0 then
                v

            else
                -v
    in
    ( signed, s3 )


{-| Float that is exactly representable as IEEE 754 float32 (for Bytes.float32
    roundtrips). We pick an integer that fits the 24-bit mantissa and scale
    by a small power of two.
-}
float32Safe : Seed -> ( Float, Seed )
float32Safe seed =
    let
        ( sign, s1 ) =
            intIn 0 1 seed

        ( mant, s2 ) =
            intIn 0 16777215 s1

        ( expShift, s3 ) =
            intIn 0 10 s2

        scale =
            toFloat (Bitwise.shiftLeftBy expShift 1)

        v =
            toFloat mant * scale
    in
    ( if sign == 0 then
        v

      else
        -v
    , s3
    )


{-| Printable ASCII char in [32, 126]. -}
char : Seed -> ( Char, Seed )
char seed =
    let
        ( code, s ) =
            intIn 32 126 seed
    in
    ( Char.fromCode code, s )


asciiString : Int -> Seed -> ( String, Seed )
asciiString len seed =
    let
        go i s acc =
            if i <= 0 then
                ( String.fromList (List.reverse acc), s )

            else
                let
                    ( c, s2 ) =
                        char s
                in
                go (i - 1) s2 (c :: acc)
    in
    go len seed []


{-| String built from a mix of ASCII, escape-sensitive chars, and BMP unicode —
    exercises JSON escaping paths.
-}
unicodeString : Int -> Seed -> ( String, Seed )
unicodeString len seed =
    let
        go i s acc =
            if i <= 0 then
                ( String.fromList (List.reverse acc), s )

            else
                let
                    ( bucket, s1 ) =
                        intIn 0 7 s

                    ( c, s2 ) =
                        case bucket of
                            0 ->
                                -- backslash
                                ( Char.fromCode 0x5C, s1 )

                            1 ->
                                -- double-quote
                                ( Char.fromCode 0x22, s1 )

                            2 ->
                                -- newline
                                ( Char.fromCode 0x0A, s1 )

                            3 ->
                                -- tab
                                ( Char.fromCode 0x09, s1 )

                            4 ->
                                let
                                    ( code, s3 ) =
                                        intIn 0x80 0xFF s1
                                in
                                ( Char.fromCode code, s3 )

                            5 ->
                                let
                                    ( code, s3 ) =
                                        intIn 0x0100 0x07FF s1
                                in
                                ( Char.fromCode code, s3 )

                            _ ->
                                char s1
                in
                go (i - 1) s2 (c :: acc)
    in
    go len seed []


listOf : Int -> (Seed -> ( a, Seed )) -> Seed -> ( List a, Seed )
listOf len gen seed =
    let
        go i s acc =
            if i <= 0 then
                ( List.reverse acc, s )

            else
                let
                    ( x, s2 ) =
                        gen s
                in
                go (i - 1) s2 (x :: acc)
    in
    go len seed []


pair : (Seed -> ( a, Seed )) -> (Seed -> ( b, Seed )) -> Seed -> ( ( a, b ), Seed )
pair gA gB seed =
    let
        ( a, s1 ) =
            gA seed

        ( b, s2 ) =
            gB s1
    in
    ( ( a, b ), s2 )


{-| Pick uniformly from a non-empty list of generators. If given an empty list,
    returns a trivially failing generator (caller bug).
-}
oneOfGen : List (Seed -> ( a, Seed )) -> Seed -> ( Maybe a, Seed )
oneOfGen gens seed =
    case gens of
        [] ->
            ( Nothing, seed )

        _ ->
            let
                n =
                    List.length gens

                ( idx, s1 ) =
                    intIn 0 (n - 1) seed

                picked =
                    List.drop idx gens |> List.head
            in
            case picked of
                Just g ->
                    let
                        ( v, s2 ) =
                            g s1
                    in
                    ( Just v, s2 )

                Nothing ->
                    ( Nothing, s1 )
