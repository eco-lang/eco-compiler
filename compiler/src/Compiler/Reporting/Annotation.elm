module Compiler.Reporting.Annotation exposing
    ( Located(..)
    , Position(..)
    , Region(..)
    , at
    , compareLocated
    , isMultiline
    , locatedDecoder
    , locatedEncoder
    , merge
    , mergeRegions
    , one
    , regionDecoder
    , regionEncoder
    , toRegion
    , toValue
    , traverse
    , zero
    )

import Bytes.Decode
import Bytes.Encode
import System.TypeCheck.IO as IO exposing (IO)
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE



-- LOCATED


type Located a
    = At Region a -- PERF see if unpacking region is helpful


compareLocated : Located comparable -> Located comparable -> Order
compareLocated (At _ a) (At _ b) =
    compare a b


traverse : (a -> IO b) -> Located a -> IO (Located b)
traverse func (At region value) =
    IO.map (At region) (func value)


toValue : Located a -> a
toValue (At _ value) =
    value


merge : Located a -> Located b -> c -> Located c
merge (At r1 _) (At r2 _) value =
    At (mergeRegions r1 r2) value



-- POSITION


type Position
    = Position Int Int


at : Position -> Position -> a -> Located a
at start end a =
    At (Region start end) a



-- REGION


type Region
    = Region Position Position


toRegion : Located a -> Region
toRegion (At region _) =
    region


mergeRegions : Region -> Region -> Region
mergeRegions (Region start _) (Region _ end) =
    Region start end


zero : Region
zero =
    Region (Position 0 0) (Position 0 0)


one : Region
one =
    Region (Position 1 1) (Position 1 1)


isMultiline : Region -> Bool
isMultiline (Region (Position startRow _) (Position endRow _)) =
    startRow /= endRow



-- ENCODERS and DECODERS


regionEncoder : Region -> Bytes.Encode.Encoder
regionEncoder (Region start end) =
    Bytes.Encode.sequence
        [ positionEncoder start
        , positionEncoder end
        ]


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


locatedEncoder : (a -> Bytes.Encode.Encoder) -> Located a -> Bytes.Encode.Encoder
locatedEncoder encoder (At region value) =
    Bytes.Encode.sequence
        [ regionEncoder region
        , encoder value
        ]


locatedDecoder : Bytes.Decode.Decoder a -> Bytes.Decode.Decoder (Located a)
locatedDecoder decoder =
    Bytes.Decode.map2 At
        regionDecoder
        (BD.lazy (\_ -> decoder))
