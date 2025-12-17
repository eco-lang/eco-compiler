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


type ZeroBased
    = ZeroBased Int


first : ZeroBased
first =
    ZeroBased 0


second : ZeroBased
second =
    ZeroBased 1


third : ZeroBased
third =
    ZeroBased 2


next : ZeroBased -> ZeroBased
next (ZeroBased i) =
    ZeroBased (i + 1)



-- DESTRUCT


toMachine : ZeroBased -> Int
toMachine (ZeroBased index) =
    index


toHuman : ZeroBased -> Int
toHuman (ZeroBased index) =
    index + 1



-- INDEXED MAP


indexedMap : (ZeroBased -> a -> b) -> List a -> List b
indexedMap func xs =
    List.map2 func (List.map ZeroBased (List.range 0 (List.length xs - 1))) xs


{-| indexedTraverse and indexedForA are defined on `Utils`
-}



-- VERIFIED/INDEXED ZIP


type VerifiedList a
    = LengthMatch (List a)
    | LengthMismatch Int Int


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


zeroBasedEncoder : ZeroBased -> Bytes.Encode.Encoder
zeroBasedEncoder (ZeroBased zeroBased) =
    BE.int zeroBased


zeroBasedDecoder : Bytes.Decode.Decoder ZeroBased
zeroBasedDecoder =
    Bytes.Decode.map ZeroBased BD.int
