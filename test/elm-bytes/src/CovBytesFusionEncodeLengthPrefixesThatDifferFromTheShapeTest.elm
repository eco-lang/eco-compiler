module CovBytesFusionEncodeLengthPrefixesThatDifferFromTheShapeTest exposing (..)

{-| Encode length prefixes that differ from the shape.

From `SourceIR.CovBytesFusionCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: <function>

import Basics exposing (..)
import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import List exposing ((::))
import Maybe exposing (Maybe(..))
import Tuple
import Html


testValue e k xs ys =
    { otherList = E.encode (E.sequence (E.unsignedInt32 BE (List.length ys) :: List.map (\x -> E.unsignedInt8 x) xs))
    , varEndian = E.encode (E.sequence (E.unsignedInt32 e (List.length xs) :: List.map (\x -> E.unsignedInt8 x) xs))
    , u16Header = E.encode (E.sequence (E.unsignedInt16 BE (List.length xs) :: List.map (\x -> E.unsignedInt8 x) xs))
    , u8Header = E.encode (E.sequence (E.unsignedInt8 (List.length xs) :: List.map (\x -> E.unsignedInt8 x) xs))
    , absHeader = E.encode (E.sequence (E.unsignedInt32 BE (abs k) :: List.map (\x -> E.unsignedInt8 x) xs))
    , litHeader = E.encode (E.sequence (E.unsignedInt32 BE 3 :: List.map (\x -> E.unsignedInt8 x) xs))
    , litList = E.encode (E.sequence (E.unsignedInt32 BE (List.length [ 1, 2 ]) :: List.map (\x -> E.unsignedInt8 x) [ 1, 2 ]))
    , notMap = E.encode (E.sequence (E.unsignedInt32 BE (List.length xs) :: List.reverse (List.map (\x -> E.unsignedInt8 x) xs)))
    , externFn = E.encode (E.sequence (E.unsignedInt32 BE (List.length xs) :: List.map E.unsignedInt8 xs))
    }


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
