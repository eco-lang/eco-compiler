module Utils.Bytes.Decode exposing
    ( unit, bool, int, float, string
    , uintV, sintV, int64
    , maybe, list, nonempty, result, oneOrMore
    , jsonPair, assocListDict, stdDict, everySet
    , map6, map8
    , lazy
    )

{-| Reads back the bytes that `Utils.Bytes.Encode` writes. Each decoder here
reads what the encoder of the same name there writes.

The bytes carry no description of themselves: nothing in them says what type
they hold, so a decoder gives a meaningful result only on bytes written by the
matching encoder. Every fixed-width number is big-endian. A string or a list
starts with its length as an unsigned 32-bit number, counted in bytes for a
string and in elements for a list. A unit, `Maybe`, `Result` or `OneOrMore`
starts with a one-byte tag saying which case follows. Dictionaries and sets are
read as lists of their entries.

The decoders differ in how strictly they check what they read. `unit`,
`result` and `oneOrMore` fail on a tag byte they do not expect, `nonempty`
fails on an empty list, and `uintV` fails on a variable-length number (a
varint, seven bits per byte) longer than five bytes.
`bool` and `maybe` never fail on their tag: `bool` reads any byte other than 1
as `False`, and `maybe` reads any tag other than 0 as `Just`.

Beyond the decoders, the module has `map6` and `map8`, because `Bytes.Decode`
stops at `map5`, and `lazy`, for a decoder defined in terms of itself.

`Compiler.GlobalOpt.MonoInlineSimplify` names most of these decoders as strings
in its list of functions inlined regardless of size, so a renamed one silently
loses that exemption.


# Primitive Decoders

@docs unit, bool, int, float, string
@docs uintV, sintV, int64


# Container Decoders

@docs maybe, list, nonempty, result, oneOrMore


# Structured Data Decoders

@docs jsonPair, assocListDict, stdDict, everySet


# Extended Mapping Functions

@docs map6, map8


# Utility Functions

@docs lazy

-}

import Bytes
import Bytes.Decode as BD
import Compiler.Data.NonEmptyList as NE
import Compiler.Data.OneOrMore as OneOrMore exposing (OneOrMore)
import Data.Map as EveryDict
import Data.Set as EverySet exposing (EverySet)
import Dict


{-| The byte order of every fixed-width number this module reads, which is
big-endian.
-}
endian : Bytes.Endianness
endian =
    Bytes.BE


{-| A decoder for a UTF-8 string preceded by its length in bytes, as an
unsigned 32-bit number.
-}
string : BD.Decoder String
string =
    BD.unsignedInt32 endian
        |> BD.andThen BD.string


{-| A decoder for the unit value, written as a single zero byte. Any other byte
fails.
-}
unit : BD.Decoder ()
unit =
    BD.unsignedInt8
        |> BD.andThen
            (\idx ->
                case idx of
                    0 ->
                        BD.succeed ()

                    _ ->
                        BD.fail
            )


{-| A decoder for an `Int` written as a 64-bit float, which it rounds to the
nearest whole number.
-}
int : BD.Decoder Int
int =
    BD.float64 endian |> BD.map round


{-| A decoder for an `Int` written by `Utils.Bytes.Encode.int64`: a signed
32-bit high word followed by an unsigned 32-bit low word, giving
`high * 2^32 + low`.

On the native back end the result is exact over the whole 64-bit range. Under
JavaScript an `Int` is a float, so the result is exact only within 2^53.

-}
int64 : BD.Decoder Int
int64 =
    BD.map2 (\hi lo -> hi * 4294967296 + lo)
        (BD.signedInt32 endian)
        (BD.unsignedInt32 endian)


{-| A decoder for an unsigned LEB128 varint, as `Utils.Bytes.Encode.uintV`
writes it.

LEB128 stores seven bits of the number in each byte, lowest bits first, and
sets a byte's top bit when another byte follows. The decoder fails when a fifth
byte still has its top bit set, so it never reads more than five bytes.

-}
uintV : BD.Decoder Int
uintV =
    BD.unsignedInt8
        |> BD.andThen
            (\b0 ->
                if b0 < 0x80 then
                    BD.succeed b0

                else
                    uintVMore (b0 - 0x80) 128 1
            )


{-| Produces a decoder for the rest of a varint, given `acc`, the value of the
bytes already read, `scale`, the weight of the next byte's low seven bits, and
`k`, the number of bytes already read. It fails when the byte it reads is the
fifth and has its top bit set.
-}
uintVMore : Int -> Int -> Int -> BD.Decoder Int
uintVMore acc scale k =
    BD.unsignedInt8
        |> BD.andThen
            (\b ->
                if b < 0x80 then
                    BD.succeed (acc + b * scale)

                else if k >= 4 then
                    BD.fail

                else
                    uintVMore (acc + (b - 0x80) * scale) (scale * 128) (k + 1)
            )


{-| A decoder for a signed `Int` written by `Utils.Bytes.Encode.sintV`: a
zigzag-encoded `uintV` varint.

Zigzag encoding maps 0, -1, 1, -2, 2, and so on to 0, 1, 2, 3, 4, so that a
number of small magnitude takes few bytes whatever its sign.

-}
sintV : BD.Decoder Int
sintV =
    BD.map
        (\z ->
            if modBy 2 z == 0 then
                z // 2

            else
                -(z + 1) // 2
        )
        uintV


{-| A decoder for a 64-bit float.
-}
float : BD.Decoder Float
float =
    BD.float64 endian


{-| A decoder for a `Bool` written as one byte. The byte 1 is `True` and every
other byte is `False`, so this decoder never fails on the byte it reads.
-}
bool : BD.Decoder Bool
bool =
    BD.map ((==) 1) BD.unsignedInt8


{-| Produces a decoder for a list written as its number of elements, an unsigned
32-bit number, followed by each element in turn, read with `decoder`. The list
is in the order the elements were written.
-}
list : BD.Decoder a -> BD.Decoder (List a)
list decoder =
    BD.unsignedInt32 endian
        |> BD.andThen (\len -> BD.loop ( len, [] ) (listStep decoder))


{-| Produces one step of the loop in `list`: while `n` elements remain it reads
one more onto `xs`, which holds those already read, newest first, and when none
remain it finishes with `xs` reversed.
-}
listStep : BD.Decoder a -> ( Int, List a ) -> BD.Decoder (BD.Step ( Int, List a ) (List a))
listStep decoder ( n, xs ) =
    if n <= 0 then
        BD.succeed (BD.Done (List.reverse xs))

    else
        BD.map (\x -> BD.Loop ( n - 1, x :: xs )) decoder


{-| Produces a decoder for a `Maybe` written as a tag byte, followed by the
value, read with `decoder`, when the tag is not 0. A tag of 0 gives `Nothing`
and any other tag is read as `Just`.
-}
maybe : BD.Decoder a -> BD.Decoder (Maybe a)
maybe decoder =
    BD.unsignedInt8
        |> BD.andThen
            (\n ->
                if n == 0 then
                    BD.succeed Nothing

                else
                    BD.map Just decoder
            )


{-| Produces a decoder for a `Result` written as a tag byte followed by its
value: 0 for `Ok`, with the value read by `successDecoder`, and 1 for `Err`,
with the value read by `errDecoder`. Any other tag fails.
-}
result : BD.Decoder x -> BD.Decoder a -> BD.Decoder (Result x a)
result errDecoder successDecoder =
    BD.unsignedInt8
        |> BD.andThen
            (\idx ->
                case idx of
                    0 ->
                        BD.map Ok successDecoder

                    1 ->
                        BD.map Err errDecoder

                    _ ->
                        BD.fail
            )


{-| Produces a decoder that reads six values in turn, one with each decoder in
argument order, and combines them with `func`.
-}
map6 : (a -> b -> c -> d -> e -> f -> result) -> BD.Decoder a -> BD.Decoder b -> BD.Decoder c -> BD.Decoder d -> BD.Decoder e -> BD.Decoder f -> BD.Decoder result
map6 func decodeA decodeB decodeC decodeD decodeE decodeF =
    BD.map5 (\a b c d ( e, f ) -> func a b c d e f)
        decodeA
        decodeB
        decodeC
        decodeD
        (BD.map2 Tuple.pair
            decodeE
            decodeF
        )


{-| Produces a decoder that reads seven values in turn, one with each decoder in
argument order, and combines them with `func`. It is not exposed; `map8` is
built on it.
-}
map7 : (a -> b -> c -> d -> e -> f -> g -> result) -> BD.Decoder a -> BD.Decoder b -> BD.Decoder c -> BD.Decoder d -> BD.Decoder e -> BD.Decoder f -> BD.Decoder g -> BD.Decoder result
map7 func decodeA decodeB decodeC decodeD decodeE decodeF decodeG =
    map6 (\a b c d e ( f, g ) -> func a b c d e f g)
        decodeA
        decodeB
        decodeC
        decodeD
        decodeE
        (BD.map2 Tuple.pair
            decodeF
            decodeG
        )


{-| Produces a decoder that reads eight values in turn, one with each decoder in
argument order, and combines them with `func`.
-}
map8 : (a -> b -> c -> d -> e -> f -> g -> h -> result) -> BD.Decoder a -> BD.Decoder b -> BD.Decoder c -> BD.Decoder d -> BD.Decoder e -> BD.Decoder f -> BD.Decoder g -> BD.Decoder h -> BD.Decoder result
map8 func decodeA decodeB decodeC decodeD decodeE decodeF decodeG decodeH =
    map7 (\a b c d e f ( g, h ) -> func a b c d e f g h)
        decodeA
        decodeB
        decodeC
        decodeD
        decodeE
        decodeF
        (BD.map2 Tuple.pair
            decodeG
            decodeH
        )


{-| Produces a `Data.Map` dictionary decoder, reading a list of key-value pairs
and filing each under its key's projection by `toComparable`.

The dictionary is built with `Data.Map.fromList`, so the order the pairs were
written in does not matter, except that of two pairs whose keys have the same
projection, the later one is kept.

-}
assocListDict : (k -> comparable) -> BD.Decoder k -> BD.Decoder v -> BD.Decoder (EveryDict.Dict comparable k v)
assocListDict toComparable keyDecoder valueDecoder =
    list (jsonPair keyDecoder valueDecoder)
        |> BD.map (EveryDict.fromList toComparable)


{-| Produces a decoder for a core `Dict`, reading a list of key-value pairs.

The dictionary is built with `Dict.fromList`, so the order the pairs were
written in does not matter, except that of two pairs with the same key, the
later one is kept.

-}
stdDict : BD.Decoder comparable -> BD.Decoder v -> BD.Decoder (Dict.Dict comparable v)
stdDict keyDecoder valueDecoder =
    list (jsonPair keyDecoder valueDecoder)
        |> BD.map Dict.fromList


{-| Produces a decoder for a tuple whose two values are written one after the
other, with no tag or length. Despite the name, nothing here involves JSON.
-}
jsonPair : BD.Decoder a -> BD.Decoder b -> BD.Decoder ( a, b )
jsonPair =
    BD.map2 Tuple.pair


{-| Produces a `Data.Set` set decoder, reading a list of elements and filing
each under its projection by `toComparable`.

The set is built with `Data.Set.fromList`, so the order the elements were
written in does not matter, except that of two elements with the same
projection, the later one is kept.

-}
everySet : (a -> comparable) -> BD.Decoder a -> BD.Decoder (EverySet comparable a)
everySet toComparable decoder =
    list decoder
        |> BD.map (EverySet.fromList toComparable)


{-| Produces a decoder for a `Nonempty` list, in the format `list` reads. A
list of no elements fails.
-}
nonempty : BD.Decoder a -> BD.Decoder (NE.Nonempty a)
nonempty decoder =
    list decoder
        |> BD.andThen
            (\values ->
                case values of
                    x :: xs ->
                        BD.succeed (NE.Nonempty x xs)

                    [] ->
                        BD.fail
            )


{-| Produces a decoder for a `OneOrMore`, written as its tree: a tag byte of 0
followed by a single element, read with `decoder`, or a tag byte of 1 followed
by the left subtree and then the right. Any other tag fails.
-}
oneOrMore : BD.Decoder a -> BD.Decoder (OneOrMore a)
oneOrMore decoder =
    BD.unsignedInt8
        |> BD.andThen
            (\idx ->
                case idx of
                    0 ->
                        BD.map OneOrMore.one decoder

                    1 ->
                        BD.map2 OneOrMore.more
                            (lazy (\_ -> oneOrMore decoder))
                            (lazy (\_ -> oneOrMore decoder))

                    _ ->
                        BD.fail
            )


{-| Produces a decoder that runs the decoder `f` returns, calling `f` only when
decoding reaches it. A decoder can therefore be defined in terms of itself
without being built before it is used.
-}
lazy : (() -> BD.Decoder a) -> BD.Decoder a
lazy f =
    BD.succeed () |> BD.andThen f
