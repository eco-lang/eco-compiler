module Compiler.Reporting.Annotation exposing
    ( Located(..), Position(..), Region(..)
    , at, toValue, toRegion
    , compareLocated, traverse, merge
    , mergeRegions, zero, one, isMultiline
    , regionEncoder, regionDecoder, regionEncoderV, regionDecoderV
    , locatedEncoder, locatedDecoder
    )

{-| An error found in a late phase of the compiler still has to point at the
source text that caused it, so the syntax trees carry source locations. This
module defines those locations.

A _position_ is a row and a column in a source file. A _region_ is a span of
source from a start position to an end position. A _located_ value is any value
paired with the region of source it is attributed to. The positions the parser
records, as `Compiler.Parse.Primitives` describes, count rows and columns from 1
and take the end of a region to be the position just after its last character.
The types here do not check any of that: a `Position` holds any two `Int`s.

Besides the types, the module has a few functions that build, take apart and
combine located values and regions, and binary encoders and decoders for them.
A region has two binary encodings. The fixed encoding writes four integers with
`Utils.Bytes.Encode.int`. The compact encoding writes varints, which take fewer
bytes for small numbers. Bytes written with one can be read only with the
decoder of the same encoding.


# Core Types

@docs Located, Position, Region


# Working with Located Values

@docs at, toValue, toRegion
@docs compareLocated, traverse, merge


# Region Utilities

@docs mergeRegions, zero, one, isMultiline


# Serialization

@docs regionEncoder, regionDecoder, regionEncoderV, regionDecoderV
@docs locatedEncoder, locatedDecoder

-}

import Bytes.Decode
import Bytes.Encode
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE



-- ====== LOCATED ======


{-| A value together with the region of source it is attributed to.
-}
type Located a
    = At Region a


{-| Compares two located values by their values alone, so that two values at
different places in the source compare as `EQ` when the values are equal.
-}
compareLocated : Located comparable -> Located comparable -> Order
compareLocated (At _ a) (At _ b) =
    compare a b


{-| Applies `func` to the value inside a located value, threading a state
through it, and returns the final state with the result at the original region.

The type checker's `IO` from `System.TypeCheck.IO` is a function of this
shape, so this works with it without this module importing the type checker.

-}
traverse : (a -> s -> ( s, b )) -> Located a -> s -> ( s, Located b )
traverse func (At region value) s0 =
    let
        ( s1, b ) =
            func value s0
    in
    ( s1, At region b )


{-| Returns the value of a located value, without its region.
-}
toValue : Located a -> a
toValue (At _ value) =
    value


{-| Places `value` at the region running from the start of the first located
value's region to the end of the second's.

Nothing checks that the first comes before the second.

-}
merge : Located a -> Located b -> c -> Located c
merge (At r1 _) (At r2 _) value =
    At (mergeRegions r1 r2) value



-- ====== POSITION ======


{-| A point in a source file: a row, then a column.

Positions recorded by the parser count both from 1. `zero` uses row 0 and
column 0 for code that has no source.

-}
type Position
    = Position Int Int


{-| Places a value at the region from `start` to `end`.
-}
at : Position -> Position -> a -> Located a
at start end a =
    At (Region start end) a



-- ====== REGION ======


{-| A span of a source file, from a start position to an end position.
-}
type Region
    = Region Position Position


{-| Returns the region of a located value, without the value.
-}
toRegion : Located a -> Region
toRegion (At region _) =
    region


{-| Returns the region from the start of the first region to the end of the
second. Nothing checks that the first comes before the second.
-}
mergeRegions : Region -> Region -> Region
mergeRegions (Region start _) (Region _ end) =
    Region start end


{-| An empty region at row 0, column 0, which no position recorded by the parser
can hold. It stands for a value that has no location in the source.
-}
zero : Region
zero =
    Region (Position 0 0) (Position 0 0)


{-| An empty region at row 1, column 1, the first character of a file.
-}
one : Region
one =
    Region (Position 1 1) (Position 1 1)


{-| Returns whether a region's start and end are on different rows. Columns are
not looked at.
-}
isMultiline : Region -> Bool
isMultiline (Region (Position startRow _) (Position endRow _)) =
    startRow /= endRow



-- ====== ENCODERS and DECODERS ======


{-| Produces the fixed encoding of a region: start row, start column, end row
and end column, each written with `Utils.Bytes.Encode.int`.
-}
regionEncoder : Region -> Bytes.Encode.Encoder
regionEncoder (Region start end) =
    Bytes.Encode.sequence
        [ positionEncoder start
        , positionEncoder end
        ]


{-| A decoder for a region in the fixed encoding that `regionEncoder` writes.
-}
regionDecoder : Bytes.Decode.Decoder Region
regionDecoder =
    Bytes.Decode.map2 Region
        positionDecoder
        positionDecoder


{-| Produces the compact encoding of a region: start row, start column, the end
row minus the start row, and end column, as varints. The difference is written
with `Utils.Bytes.Encode.sintV`, so it may be negative, and the other three
with `Utils.Bytes.Encode.uintV`, so they must not be.

The ranges `Utils.Bytes.Encode.uintV` and `Utils.Bytes.Encode.sintV` require
are not checked here. Only `regionDecoderV` can read the result.

-}
regionEncoderV : Region -> Bytes.Encode.Encoder
regionEncoderV (Region (Position r1 c1) (Position r2 c2)) =
    Bytes.Encode.sequence [ BE.uintV r1, BE.uintV c1, BE.sintV (r2 - r1), BE.uintV c2 ]


{-| A decoder for a region in the compact encoding that `regionEncoderV` writes.
-}
regionDecoderV : Bytes.Decode.Decoder Region
regionDecoderV =
    Bytes.Decode.map4 (\r1 c1 dr c2 -> Region (Position r1 c1) (Position (r1 + dr) c2))
        BD.uintV
        BD.uintV
        BD.sintV
        BD.uintV


{-| Produces the fixed encoding of a position: its row, then its column, each
written with `Utils.Bytes.Encode.int`.
-}
positionEncoder : Position -> Bytes.Encode.Encoder
positionEncoder (Position start end) =
    Bytes.Encode.sequence
        [ BE.int start
        , BE.int end
        ]


{-| A decoder for a position that `positionEncoder` writes.
-}
positionDecoder : Bytes.Decode.Decoder Position
positionDecoder =
    Bytes.Decode.map2 Position
        BD.int
        BD.int


{-| Produces an encoding of a located value: its region in the fixed encoding
that `regionEncoder` writes, then its value as `encoder` writes it.
-}
locatedEncoder : (a -> Bytes.Encode.Encoder) -> Located a -> Bytes.Encode.Encoder
locatedEncoder encoder (At region value) =
    Bytes.Encode.sequence
        [ regionEncoder region
        , encoder value
        ]


{-| Produces a decoder for a located value that `locatedEncoder` writes: a
region in the fixed encoding, then a value that `decoder` reads.
-}
locatedDecoder : Bytes.Decode.Decoder a -> Bytes.Decode.Decoder (Located a)
locatedDecoder decoder =
    Bytes.Decode.map2 At
        regionDecoder
        (BD.lazy (\_ -> decoder))
