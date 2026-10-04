module Compiler.Data.Index exposing
    ( ZeroBased
    , first, second, third, next
    , toMachine, toHuman
    , indexedMap, indexedZipWith, VerifiedList(..)
    , zeroBasedEncoder, zeroBasedDecoder, zeroBasedEncoderV, zeroBasedDecoderV
    )

{-| The compiler counts positions from zero and error messages count them from
one, and this module keeps the two counts from being mixed up.

A _position_ is the place of one item in a sequence, such as a constructor in
its type's declaration, an entry in a list literal or an argument in a call.
A position held as a `ZeroBased` value cannot be used where an `Int` is
expected. Turning one into a number takes either `toMachine`, the count from
zero, or `toHuman`, the count from one that a reader of a message expects, so
every conversion says which count it means.

The module also numbers the elements of lists as it maps over them.
`indexedZipWith` combines two lists element by element and, when their lengths
differ, reports the length of each instead of dropping the extra elements.

A position has two binary encodings: `zeroBasedEncoder` writes the count from
zero as a 64-bit float, and `zeroBasedEncoderV` writes it as a varint. They are
not interchangeable, so bytes must be read with the decoder that matches the
encoder that wrote them.


# Zero-Based Index

@docs ZeroBased


# Common Indices

@docs first, second, third, next


# Conversion

@docs toMachine, toHuman


# Indexed Operations

@docs indexedMap, indexedZipWith, VerifiedList


# Serialization

@docs zeroBasedEncoder, zeroBasedDecoder, zeroBasedEncoderV, zeroBasedDecoderV

-}

import Bytes.Decode
import Bytes.Encode
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE



-- ====== ZERO BASED ======


{-| A position in a sequence, counted from zero and kept apart from an
ordinary `Int`.

A position is made by starting from `first`, `second` or `third` and stepping
with `next`, by `indexedMap` or `indexedZipWith`, which number list elements
from `first`, or by decoding. A position made by counting is never negative; a
decoded one is whatever was encoded. Reading a position as a number takes
`toMachine` or `toHuman`.

-}
type ZeroBased
    = ZeroBased Int


{-| The position of the first item, which `toHuman` turns into 1.
-}
first : ZeroBased
first =
    ZeroBased 0


{-| The position of the second item, which `toHuman` turns into 2.
-}
second : ZeroBased
second =
    ZeroBased 1


{-| The position of the third item, which `toHuman` turns into 3.
-}
third : ZeroBased
third =
    ZeroBased 2


{-| Returns the position after the given one.
-}
next : ZeroBased -> ZeroBased
next (ZeroBased i) =
    ZeroBased (i + 1)



-- ====== DESTRUCT ======


{-| Returns the position counted from zero, so `first` gives 0.
-}
toMachine : ZeroBased -> Int
toMachine (ZeroBased index) =
    index


{-| Returns the position counted from one, as a reader of a message counts it,
so `first` gives 1.
-}
toHuman : ZeroBased -> Int
toHuman (ZeroBased index) =
    index + 1



-- ====== INDEXED MAP ======


{-| Applies `func` to each element of the list together with its position,
counted from `first`, and returns the results in order.
-}
indexedMap : (ZeroBased -> a -> b) -> List a -> List b
indexedMap func xs =
    List.map2 func (List.map ZeroBased (List.range 0 (List.length xs - 1))) xs



-- ====== VERIFIED/INDEXED ZIP ======


{-| The result of combining two lists element by element, which succeeds only
when the lists have the same length.

`LengthMatch` carries the combined list, one element for each pair.

`LengthMismatch` carries two lengths, the first list's and then the second's.
From `indexedZipWith` each is the length of the whole list, not of the part
that was paired.

-}
type VerifiedList a
    = LengthMatch (List a)
    | LengthMismatch Int Int


{-| Combines `listX` and `listY` element by element, giving `func` each pair's
position, counted from `first`, along with the two elements.

When the lists have the same length the result is `LengthMatch` with the
combined list in order. Otherwise it is `LengthMismatch` with the length of
`listX` and then the length of `listY`.

-}
indexedZipWith : (ZeroBased -> a -> b -> c) -> List a -> List b -> VerifiedList c
indexedZipWith func listX listY =
    indexedZipWithHelp func 0 listX listY []


{-| Continues the zip that `indexedZipWith` starts, from position `index`,
where `revListZ` holds the results for the earlier positions in reverse order.

On a mismatch, `index` is added to each remaining length. `indexedZipWith`
starts `index` at 0, so the sums are the lengths of the whole lists.

-}
indexedZipWithHelp : (ZeroBased -> a -> b -> c) -> Int -> List a -> List b -> List c -> VerifiedList c
indexedZipWithHelp func index listX listY revListZ =
    case ( listX, listY ) of
        ( [], [] ) ->
            LengthMatch (List.reverse revListZ)

        ( x :: xs, y :: ys ) ->
            indexedZipWithHelp func (index + 1) xs ys (func (ZeroBased index) x y :: revListZ)

        _ ->
            LengthMismatch (index + List.length listX) (index + List.length listY)



-- ====== ENCODERS and DECODERS ======


{-| Encodes a position as its count from zero, written as
`Utils.Bytes.Encode.int` writes an integer, a 64-bit float.
-}
zeroBasedEncoder : ZeroBased -> Bytes.Encode.Encoder
zeroBasedEncoder (ZeroBased zeroBased) =
    BE.int zeroBased


{-| A decoder for a position written by `zeroBasedEncoder`.
-}
zeroBasedDecoder : Bytes.Decode.Decoder ZeroBased
zeroBasedDecoder =
    Bytes.Decode.map ZeroBased BD.int


{-| Encodes a position as its count from zero, written as the varint of
`Utils.Bytes.Encode.uintV`, which takes one byte for a count below 128.

`uintV` requires a count below 2^31 and does not check it. Read the bytes back
with `zeroBasedDecoderV`, not `zeroBasedDecoder`.

-}
zeroBasedEncoderV : ZeroBased -> Bytes.Encode.Encoder
zeroBasedEncoderV (ZeroBased zeroBased) =
    BE.uintV zeroBased


{-| A decoder for a position written by `zeroBasedEncoderV`.
-}
zeroBasedDecoderV : Bytes.Decode.Decoder ZeroBased
zeroBasedDecoderV =
    Bytes.Decode.map ZeroBased BD.uintV
