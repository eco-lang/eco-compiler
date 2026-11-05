module CovBytesFusionEncodeSequenceOfAParameterAndALetRecElementTest exposing (..)

{-| Encode sequence of a parameter and a let-rec element.

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


testValue encs x =
    ( E.encode (E.sequence encs)
    , E.encode
        (E.sequence
            [ let
                go n =
                    if n <= 0 then
                        0

                    else
                        go (n - 1)
              in
              E.unsignedInt8 (go x)
            , E.unsignedInt8 x
            ]
        )
    )


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
