module CovBytesFusionDecodeLoopsWhoseCombinatorsAreTheWrongCallTest exposing (..)

{-| Decode loops whose combinators are the wrong call.

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


testValue dflt stepBody b =
    { elseAndThen =
        D.decode
            (D.loop ( 3, [] )
                (\( n, acc ) ->
                    if n <= 0 then
                        D.succeed (D.Done acc)

                    else
                        D.andThen (\x -> D.succeed (D.Loop ( n - 1, x :: acc ))) D.unsignedInt8
                )
            )
            b
    , elseParam =
        D.decode
            (D.loop ( 3, [] )
                (\( n, acc ) ->
                    if n <= 0 then
                        D.succeed (D.Done acc)

                    else
                        dflt
                )
            )
            b
    , sentinelMap =
        D.decode
            (D.loop []
                (\acc ->
                    D.map
                        (\x ->
                            if x == 0 then
                                D.Done acc

                            else
                                D.Loop (x :: acc)
                        )
                        D.unsignedInt8
                )
            )
            b
    , sentinelParam = D.decode (D.loop [] (\acc -> stepBody)) b
    }


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
