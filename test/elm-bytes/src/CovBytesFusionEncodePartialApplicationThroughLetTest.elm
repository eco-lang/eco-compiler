module CovBytesFusionEncodePartialApplicationThroughLetTest exposing (..)

{-| Encode partial application through let.

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


testValue x =
    let
        w =
            E.unsignedInt16 BE
    in
    E.encode (E.sequence [ w x, E.unsignedInt8 x ])


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
