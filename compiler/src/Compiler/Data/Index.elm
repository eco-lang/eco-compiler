module Compiler.Data.Index exposing
    ( ZeroBased
    , first, second, third, next
    , toMachine, toHuman
    , indexedMap, indexedZipWith, VerifiedList(..)
    , zeroBasedEncoder, zeroBasedDecoder
    )

{-| Zero-based indexing with type safety and length-verified list operations.

This module provides a ZeroBased type that wraps integers to distinguish indices from
arbitrary numbers, along with utilities for indexed operations and length verification
when zipping lists.


# Zero-Based Index

@docs ZeroBased


# Common Indices

@docs first, second, third, next


# Conversion

@docs toMachine, toHuman


# Indexed Operations

@docs indexedMap, indexedZipWith, VerifiedList


# Serialization

@docs zeroBasedEncoder, zeroBasedDecoder

-}

import Bytes.Decode
import Bytes.Encode
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE



-- ZERO BASED


{-| A type-safe wrapper for zero-based indices.
Distinguishes indices from arbitrary integers to prevent confusion.
-}
type ZeroBased
    = ZeroBased Int


{-| The first index (0 in zero-based indexing).
-}
first : ZeroBased
first =
    ZeroBased 0


{-| The second index (1 in zero-based indexing).
-}
second : ZeroBased
second =
    ZeroBased 1


{-| The third index (2 in zero-based indexing).
-}
third : ZeroBased
third =
    ZeroBased 2


{-| Get the next index after the given one (increment by 1).
-}
next : ZeroBased -> ZeroBased
next (ZeroBased i) =
    ZeroBased (i + 1)



-- DESTRUCT


{-| Convert a zero-based index to a machine integer (0-indexed).
Returns the raw integer value suitable for array/list indexing.
-}
toMachine : ZeroBased -> Int
toMachine (ZeroBased index) =
    index


{-| Convert a zero-based index to a human-readable integer (1-indexed).
Returns the index plus one, suitable for display to users.
-}
toHuman : ZeroBased -> Int
toHuman (ZeroBased index) =
    index + 1



-- INDEXED MAP


{-| Map over a list with zero-based indices provided to the mapping function.
The function receives both the index and the element at that position.
-}
indexedMap : (ZeroBased -> a -> b) -> List a -> List b
indexedMap func xs =
    List.map2 func (List.map ZeroBased (List.range 0 (List.length xs - 1))) xs



-- NOTE: indexedTraverse and indexedForA are defined on `Utils`
-- VERIFIED/INDEXED ZIP


{-| Result of an indexed zip operation that verifies list lengths match.
LengthMatch contains the successfully zipped list when lengths are equal.
LengthMismatch contains the actual lengths of both lists when they differ.
-}
type VerifiedList a
    = LengthMatch (List a)
    | LengthMismatch Int Int


{-| Zip two lists with a function that receives the zero-based index and both elements.
Returns LengthMatch with the result if both lists have the same length, or
LengthMismatch with both list lengths if they differ.
-}
indexedZipWith : (ZeroBased -> a -> b -> c) -> List a -> List b -> VerifiedList c
indexedZipWith func listX listY =
    indexedZipWithHelp func 0 listX listY []


indexedZipWithHelp : (ZeroBased -> a -> b -> c) -> Int -> List a -> List b -> List c -> VerifiedList c
indexedZipWithHelp func index listX listY revListZ =
    case ( listX, listY ) of
        ( [], [] ) ->
            LengthMatch (List.reverse revListZ)

        ( x :: xs, y :: ys ) ->
            indexedZipWithHelp func (index + 1) xs ys (func (ZeroBased index) x y :: revListZ)

        _ ->
            LengthMismatch (index + List.length listX) (index + List.length listY)



-- ENCODERS and DECODERS


{-| Encode a zero-based index to bytes as an integer.
-}
zeroBasedEncoder : ZeroBased -> Bytes.Encode.Encoder
zeroBasedEncoder (ZeroBased zeroBased) =
    BE.int zeroBased


{-| Decode a zero-based index from bytes.
Reads an integer and wraps it in the ZeroBased type.
-}
zeroBasedDecoder : Bytes.Decode.Decoder ZeroBased
zeroBasedDecoder =
    Bytes.Decode.map ZeroBased BD.int
