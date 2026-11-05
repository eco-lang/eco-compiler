module CovBytesFusionDecodeSentinelLoopTest exposing (..)

{-| Decode sentinel loop.

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
    D.decode
        (D.loop []
            (\acc ->
                D.andThen
                    (\byte ->
                        if 0 == byte then
                            D.succeed (D.Done (List.reverse acc))

                        else
                            D.succeed (D.Loop (byte :: acc))
                    )
                    (D.unsignedInt16 BE)
            )
        )
        b


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
