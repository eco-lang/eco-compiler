module Compiler.Reporting.Annotation exposing
    ( Located(..), Position(..), Region(..)
    , at, toValue, toRegion
    , compareLocated, traverse, merge
    , mergeRegions, zero, one, isMultiline
    , regionEncoder, regionDecoder
    , locatedEncoder, locatedDecoder
    )

{-| Source location tracking for compiler error reporting.

This module provides types and utilities for tracking the position of syntax
elements in source code. Every significant AST node is annotated with its
location, enabling precise error messages that point to exactly where
problems occur.


# Core Types

@docs Located, Position, Region


# Working with Located Values

@docs at, toValue, toRegion
@docs compareLocated, traverse, merge


# Region Utilities

@docs mergeRegions, zero, one, isMultiline


# Serialization

@docs regionEncoder, regionDecoder
@docs locatedEncoder, locatedDecoder

-}

import Bytes.Decode
import Bytes.Encode
import System.TypeCheck.IO as IO exposing (IO)
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE



-- LOCATED


{-| A value annotated with its source location.

Wraps any value with information about where it appears in the source code,
enabling precise error reporting.

-}
type Located a
    = At Region a -- PERF see if unpacking region is helpful


{-| Compare two located values based on their underlying values, ignoring location.

Useful for sorting or equality checks where location is irrelevant.

-}
compareLocated : Located comparable -> Located comparable -> Order
compareLocated (At _ a) (At _ b) =
    compare a b


{-| Apply an IO-producing function to a located value, preserving its location.

This is a monadic map operation that transforms the value while keeping
the region annotation intact.

-}
traverse : (a -> IO b) -> Located a -> IO (Located b)
traverse func (At region value) =
    IO.map (At region) (func value)


{-| Extract the value from a located wrapper, discarding location information.
-}
toValue : Located a -> a
toValue (At _ value) =
    value


{-| Create a located value spanning the combined region of two other located values.

Takes the start position from the first located value and the end position
from the second, wrapping a new value with this merged region.

-}
merge : Located a -> Located b -> c -> Located c
merge (At r1 _) (At r2 _) value =
    At (mergeRegions r1 r2) value



-- POSITION


{-| A single position in source code, represented as row and column numbers.

Both row and column are 1-indexed (first character is at row 1, column 1).

-}
type Position
    = Position Int Int


{-| Create a located value from start and end positions.

Constructs a region from the two positions and wraps the value with it.

-}
at : Position -> Position -> a -> Located a
at start end a =
    At (Region start end) a



-- REGION


{-| A contiguous span in source code, from a start position to an end position.

Represents the location of a syntactic construct in the source file.

-}
type Region
    = Region Position Position


{-| Extract the region from a located value, discarding the value itself.
-}
toRegion : Located a -> Region
toRegion (At region _) =
    region


{-| Combine two regions into one spanning from the start of the first to the end of the second.

Useful for representing the location of a construct that encompasses multiple sub-parts.

-}
mergeRegions : Region -> Region -> Region
mergeRegions (Region start _) (Region _ end) =
    Region start end


{-| A zero-width region at position (0, 0).

Used for synthetic or compiler-generated constructs with no source location.

-}
zero : Region
zero =
    Region (Position 0 0) (Position 0 0)


{-| A zero-width region at position (1, 1).

Represents the very beginning of a source file.

-}
one : Region
one =
    Region (Position 1 1) (Position 1 1)


{-| Check if a region spans multiple lines.

Returns True if the start and end positions are on different rows.

-}
isMultiline : Region -> Bool
isMultiline (Region (Position startRow _) (Position endRow _)) =
    startRow /= endRow



-- ENCODERS and DECODERS


{-| Encode a region to bytes for serialization.

Encodes both the start and end positions sequentially.

-}
regionEncoder : Region -> Bytes.Encode.Encoder
regionEncoder (Region start end) =
    Bytes.Encode.sequence
        [ positionEncoder start
        , positionEncoder end
        ]


{-| Decode a region from bytes.

Expects the bytes to contain a start position followed by an end position.

-}
regionDecoder : Bytes.Decode.Decoder Region
regionDecoder =
    Bytes.Decode.map2 Region
        positionDecoder
        positionDecoder


positionEncoder : Position -> Bytes.Encode.Encoder
positionEncoder (Position start end) =
    Bytes.Encode.sequence
        [ BE.int start
        , BE.int end
        ]


positionDecoder : Bytes.Decode.Decoder Position
positionDecoder =
    Bytes.Decode.map2 Position
        BD.int
        BD.int


{-| Encode a located value to bytes using a custom encoder for the value.

Encodes the region first, then the wrapped value using the provided encoder.

-}
locatedEncoder : (a -> Bytes.Encode.Encoder) -> Located a -> Bytes.Encode.Encoder
locatedEncoder encoder (At region value) =
    Bytes.Encode.sequence
        [ regionEncoder region
        , encoder value
        ]


{-| Decode a located value from bytes using a custom decoder for the value.

Decodes the region first, then the value using the provided decoder,
and combines them into a Located value.

-}
locatedDecoder : Bytes.Decode.Decoder a -> Bytes.Decode.Decoder (Located a)
locatedDecoder decoder =
    Bytes.Decode.map2 At
        regionDecoder
        (BD.lazy (\_ -> decoder))
