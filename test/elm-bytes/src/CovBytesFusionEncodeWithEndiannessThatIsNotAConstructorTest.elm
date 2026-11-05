module CovBytesFusionEncodeWithEndiannessThatIsNotAConstructorTest exposing (..)

{-| Encode with endianness that is not a constructor.

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


testValue e x =
    E.encode (E.sequence [ E.unsignedInt16 big x, E.unsignedInt16 e x, E.float64 e 1.0 ])


big : Endianness
big =
    BE


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
