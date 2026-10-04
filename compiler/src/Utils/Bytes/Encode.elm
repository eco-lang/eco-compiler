module Utils.Bytes.Encode exposing
    ( unit, bool, int, float, string
    , uintV, sintV, int64
    , maybe, list, nonempty, result, oneOrMore
    , jsonPair, assocListDict, stdDict, everySet
    )

{-| The compiler saves values as bytes, in its cache files among other places, and
must later read back exactly what it wrote. This module writes that binary
format, and `Utils.Bytes.Decode` reads it.

It holds encoders for primitives and for common containers. An encoding is
the encodings of its parts back to back, with no field names or separators
between them, so bytes can be read only by a decoder that expects the same
parts in the same order. Each encoder here has a decoder of the same name in
`Utils.Bytes.Decode`, and the two must stay byte for byte in step.

Fixed-width numbers of more than one byte are big-endian. A _tag_ is a single
byte that says which case follows, as in `maybe`, `result` and `oneOrMore`. A
string or list starts with a _length prefix_, an unsigned 32-bit count: of UTF-8
bytes for `string`, and of elements for `list` and the containers written as a
list.

An Elm `Int` is a 64-bit integer on the native back end and a JavaScript number
on the JavaScript back end. Integers have three encodings: `int` writes a
64-bit float, `int64` writes two 32-bit words, and `uintV` and `sintV` write a
_varint_, which is shorter for smaller numbers.

`Compiler.GlobalOpt.MonoInlineSimplify` names most of these encoders, as strings,
in its list of functions inlined whatever their size, so renaming one loses
that exemption and reports no error.


# Primitive Encoders

@docs unit, bool, int, float, string
@docs uintV, sintV, int64


# Container Encoders

@docs maybe, list, nonempty, result, oneOrMore


# Structured Data Encoders

@docs jsonPair, assocListDict, stdDict, everySet

-}

import Bytes
import Bytes.Encode as BE
import Compiler.Data.NonEmptyList as NE
import Compiler.Data.OneOrMore exposing (OneOrMore(..))
import Data.Map as EveryDict
import Data.Set as EverySet exposing (EverySet)
import Dict


{-| The byte order of the fixed-width numbers this module writes, most
significant byte first.
-}
endian : Bytes.Endianness
endian =
    Bytes.BE


{-| Encodes `()` as a single zero byte.
-}
unit : () -> BE.Encoder
unit () =
    BE.unsignedInt8 0


{-| Encodes an integer as a 64-bit float.

This is exact for integers of magnitude up to 2^53. On the native back end an
`Int` can be larger, and a larger one may not be written exactly; `int64` writes
any 64-bit integer exactly.

-}
int : Int -> BE.Encoder
int =
    toFloat >> BE.float64 endian


{-| Encodes an integer as two 32-bit words, exactly for every 64-bit integer:
first the signed high word `hi`, then the unsigned low word `lo`, where
`n = hi * 2^32 + lo` and `0 <= lo < 2^32`.

`lo` is `modBy 2^32 n`, which is never negative, so `n - lo` is an exact
multiple of 2^32 and `hi` is the exact quotient. On the JavaScript back end
`//` works on 32 bits, and the quotient is still exact there for an `n` in the
64-bit range, whose `hi` fits in a signed 32-bit word.

-}
int64 : Int -> BE.Encoder
int64 n =
    let
        lo : Int
        lo =
            modBy 4294967296 n

        hi : Int
        hi =
            (n - lo) // 4294967296
    in
    BE.sequence
        [ BE.signedInt32 endian hi
        , BE.unsignedInt32 endian lo
        ]


{-| Encodes a non-negative integer as an unsigned LEB128 varint: seven bits per
byte, lowest seven first, with the top bit of a byte set when another byte
follows. A number below 128 takes one byte and one below 2^14 takes two.

`n` must satisfy `0 <= n < 2^31`, and nothing checks it. Within that range
`modBy` and `//` give the same results on the JavaScript back end, where `//`
works on 32 bits, as on the native one, so both write the same bytes, at most
five of them. A negative `n` is written as one byte that does not represent
it. On the native back end a number of 2^35 or more takes more than the five
bytes that `Utils.Bytes.Decode.uintV` accepts.

-}
uintV : Int -> BE.Encoder
uintV n =
    if n < 0x80 then
        BE.unsignedInt8 n

    else if n < 0x4000 then
        BE.sequence [ BE.unsignedInt8 (0x80 + modBy 128 n), BE.unsignedInt8 (n // 128) ]

    else
        BE.sequence (uintVBytes n)


{-| Returns the varint bytes of `n` as `uintV` lays them out, one encoder per
byte.
-}
uintVBytes : Int -> List BE.Encoder
uintVBytes n =
    if n < 0x80 then
        [ BE.unsignedInt8 n ]

    else
        BE.unsignedInt8 (0x80 + modBy 128 n) :: uintVBytes (n // 128)


{-| Encodes a possibly negative integer as a varint, by _zigzag_ mapping it to
a non-negative one and writing that with `uintV`. Zigzag sends 0, -1, 1, -2,
2 and so on to 0, 1, 2, 3, 4, so a number of small magnitude takes few bytes
whatever its sign.

`n` must satisfy `-2^30 <= n < 2^30`, which keeps the mapped number within the
range `uintV` requires. Nothing checks it.

-}
sintV : Int -> BE.Encoder
sintV n =
    uintV
        (if n >= 0 then
            2 * n

         else
            -2 * n - 1
        )


{-| Encodes a float as a 64-bit IEEE 754 double.
-}
float : Float -> BE.Encoder
float =
    BE.float64 endian


{-| Encodes a string as its length in UTF-8 bytes, an unsigned 32-bit number,
followed by those bytes.
-}
string : String -> BE.Encoder
string str =
    BE.sequence
        [ BE.unsignedInt32 endian (BE.getStringWidth str)
        , BE.string str
        ]


{-| Encodes `True` as the byte 1 and `False` as the byte 0.
-}
bool : Bool -> BE.Encoder
bool value =
    BE.unsignedInt8
        (if value then
            1

         else
            0
        )


{-| Encodes a list as its number of elements, an unsigned 32-bit number,
followed by each element written with `encoder`, in list order.
-}
list : (a -> BE.Encoder) -> List a -> BE.Encoder
list encoder aList =
    BE.sequence
        (BE.unsignedInt32 endian (List.length aList)
            :: List.map encoder aList
        )


{-| Encodes `Just` a value as the tag byte 1 followed by the value, and `Nothing`
as the single byte 0.
-}
maybe : (a -> BE.Encoder) -> Maybe a -> BE.Encoder
maybe encoder maybeValue =
    case maybeValue of
        Just value ->
            BE.sequence
                [ BE.unsignedInt8 1
                , encoder value
                ]

        Nothing ->
            BE.unsignedInt8 0


{-| Encodes a non-empty list exactly as `list` encodes the same elements.
-}
nonempty : (a -> BE.Encoder) -> NE.Nonempty a -> BE.Encoder
nonempty encoder (NE.Nonempty x xs) =
    list encoder (x :: xs)


{-| Encodes `Ok` as the tag byte 0 followed by the value written with
`successEncoder`, and `Err` as the tag byte 1 followed by the error written
with `errEncoder`.
-}
result : (x -> BE.Encoder) -> (a -> BE.Encoder) -> Result x a -> BE.Encoder
result errEncoder successEncoder resultValue =
    case resultValue of
        Ok value ->
            BE.sequence
                [ BE.unsignedInt8 0
                , successEncoder value
                ]

        Err err ->
            BE.sequence
                [ BE.unsignedInt8 1
                , errEncoder err
                ]


{-| Encodes a `Data.Map` dictionary as a `list` of its key-value pairs, each
written as `jsonPair` writes it.

The pairs are in descending order of their projected keys, the reverse of
`Data.Map.toList`'s order. `keyComparison` is ignored, as `Data.Map` describes.

-}
assocListDict : (k -> BE.Encoder) -> (v -> BE.Encoder) -> EveryDict.Dict c k v -> BE.Encoder
assocListDict keyEncoder valueEncoder =
    EveryDict.toList >> List.reverse >> list (jsonPair keyEncoder valueEncoder)


{-| Encodes a core `Dict` as a `list` of its key-value pairs in ascending key
order, each written as `jsonPair` writes it.
-}
stdDict : (comparable -> BE.Encoder) -> (v -> BE.Encoder) -> Dict.Dict comparable v -> BE.Encoder
stdDict keyEncoder valueEncoder =
    Dict.toList >> list (jsonPair keyEncoder valueEncoder)


{-| Encodes a pair as its first element followed by its second, with nothing
before or between them. Nothing about the encoding is JSON.
-}
jsonPair : (a -> BE.Encoder) -> (b -> BE.Encoder) -> ( a, b ) -> BE.Encoder
jsonPair encoderA encoderB ( a, b ) =
    BE.sequence
        [ encoderA a
        , encoderB b
        ]


{-| Encodes a `Data.Set` set as a `list` of its elements, in descending order of
their projections. `keyComparison` is ignored, as `Data.Set` describes.
-}
everySet : (a -> BE.Encoder) -> EverySet c a -> BE.Encoder
everySet encoder =
    EverySet.toList >> List.reverse >> list encoder


{-| Encodes a `OneOrMore` tree node by node, keeping its shape: a `One` as the
tag byte 0 followed by its element, and a `More` as the tag byte 1 followed by
its left subtree and then its right.
-}
oneOrMore : (a -> BE.Encoder) -> OneOrMore a -> BE.Encoder
oneOrMore encoder oneOrMore_ =
    case oneOrMore_ of
        One value ->
            BE.sequence
                [ BE.unsignedInt8 0
                , encoder value
                ]

        More left right ->
            BE.sequence
                [ BE.unsignedInt8 1
                , oneOrMore encoder left
                , oneOrMore encoder right
                ]
