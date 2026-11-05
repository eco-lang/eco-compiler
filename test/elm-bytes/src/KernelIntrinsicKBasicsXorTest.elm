module KernelIntrinsicKBasicsXorTest exposing (..)

{-| K Basics.xor.

From `SourceIR.KernelIntrinsicCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: True

import Basics exposing (..)
import Bitwise exposing (..)
import Bytes exposing (..)
import Bytes.Decode exposing (..)
import Bytes.Encode exposing (..)
import Char exposing (..)
import List exposing (..)
import Maybe exposing (..)
import String exposing (..)
import Tuple exposing (..)
import Html


testValue =
    Basics.xor Basics.True Basics.False


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
