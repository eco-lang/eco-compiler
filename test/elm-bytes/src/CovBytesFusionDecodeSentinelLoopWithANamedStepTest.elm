module CovBytesFusionDecodeSentinelLoopWithANamedStepTest exposing (..)

{-| Decode sentinel loop with a named step.

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
    D.decode (D.loop [] step) b


step : List Int -> D.Decoder (D.Step (List Int) (List Int))
step acc =
    D.andThen
        (\x ->
            if x == 0 then
                D.succeed (D.Done acc)

            else
                D.succeed (D.Loop (x :: acc))
        )
        D.unsignedInt8


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
