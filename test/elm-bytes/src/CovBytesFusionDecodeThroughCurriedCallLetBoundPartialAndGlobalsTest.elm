module CovBytesFusionDecodeThroughCurriedCallLetBoundPartialAndGlobalsTest exposing (..)

{-| Decode through curried call, let-bound partial and globals.

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
        rd =
            D.unsignedInt16

        rd2 =
            D.map2 (\x y -> x + y) D.unsignedInt8
    in
    { a = D.decode (D.map2 (\x y -> x + y) D.unsignedInt8 D.unsignedInt8) b
    , c = D.decode (rd BE) b
    , d = D.decode dec b
    , e = D.decode (decE LE) b
    , f = D.decode (rd2 D.signedInt8) b
    }


decE : Endianness -> D.Decoder Int
decE e =
    D.unsignedInt16 e


dec : D.Decoder Int
dec =
    D.unsignedInt8


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
