module CovBytesFusionDecodeCountLoopsOfEveryIntegerWidthTest exposing (..)

{-| Decode count loops of every integer width.

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
    { s16 =
        D.decode
            (D.loop ( 2, [] )
                (\( n, acc ) ->
                    if n <= 0 then
                        D.succeed (D.Done acc)

                    else
                        D.map (\x -> D.Loop ( n - 1, x :: acc )) (D.signedInt16 BE)
                )
            )
            b
    , u32 =
        D.decode
            (D.loop ( 2, [] )
                (\( n, acc ) ->
                    if n <= 0 then
                        D.succeed (D.Done acc)

                    else
                        D.map (\x -> D.Loop ( n - 1, x :: acc )) (D.unsignedInt32 LE)
                )
            )
            b
    , s32 =
        D.decode
            (D.loop ( 2, [] )
                (\( n, acc ) ->
                    if n <= 0 then
                        D.succeed (D.Done acc)

                    else
                        D.map (\x -> D.Loop ( n - 1, x :: acc )) (D.signedInt32 BE)
                )
            )
            b
    , sentinelS8 =
        D.decode
            (D.loop []
                (\acc ->
                    D.andThen
                        (\x ->
                            if x == 0 then
                                D.succeed (D.Done acc)

                            else
                                D.succeed (D.Loop (x :: acc))
                        )
                        D.signedInt8
                )
            )
            b
    }


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
