module CovBytesFusionDecodeCountLoopWithLetBoundCountTest exposing (..)

{-| Decode count loop with let-bound count.

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


testValue b =
    let
        count =
            4
    in
    D.decode
        (D.loop ( count, [] )
            (\( n, acc ) ->
                if n <= 0 then
                    D.succeed (D.Done (List.reverse acc))

                else
                    D.map (\x -> D.Loop ( n - 1, x :: acc )) (D.unsignedInt16 LE)
            )
        )
        b


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
