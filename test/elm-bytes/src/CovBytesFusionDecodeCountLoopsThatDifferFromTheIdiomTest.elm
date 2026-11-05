module CovBytesFusionDecodeCountLoopsThatDifferFromTheIdiomTest exposing (..)

{-| Decode count loops that differ from the idiom.

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


testValue k f pair b =
    { nonEmptyAcc =
        D.decode
            (D.loop ( 3, [ 1 ] )
                (\( n, acc ) ->
                    if n <= 0 then
                        D.succeed (D.Done acc)

                    else
                        D.map (\x -> D.Loop ( n - 1, x :: acc )) D.signedInt8
                )
            )
            b
    , ltCond =
        D.decode
            (D.loop ( 3, [] )
                (\( n, acc ) ->
                    if n < 1 then
                        D.succeed (D.Done acc)

                    else
                        D.map (\x -> D.Loop ( n - 1, x :: acc )) (D.unsignedInt32 BE)
                )
            )
            b
    , oneArgCond =
        D.decode
            (D.loop ( 3, [] )
                (\( n, acc ) ->
                    if f n then
                        D.succeed (D.Done acc)

                    else
                        D.map (\x -> D.Loop ( n - 1, x :: acc )) (D.signedInt32 LE)
                )
            )
            b
    , noDecrement =
        D.decode
            (D.loop ( 3, [] )
                (\( n, acc ) ->
                    if n <= 0 then
                        D.succeed (D.Done acc)

                    else
                        D.map (\x -> D.Loop ( n, x :: acc )) (D.float32 LE)
                )
            )
            b
    , noCons =
        D.decode
            (D.loop ( 3, [] )
                (\( n, acc ) ->
                    if n <= 0 then
                        D.succeed (D.Done acc)

                    else
                        D.map (\x -> D.Loop ( n - 1, acc )) (D.signedInt16 BE)
                )
            )
            b
    , doubleReverse =
        D.decode
            (D.loop ( 3, [] )
                (\( n, acc ) ->
                    if n <= 0 then
                        D.succeed (D.Done (List.reverse (List.reverse acc)))

                    else
                        D.map (\x -> D.Loop ( n - 1, x :: acc )) D.unsignedInt8
                )
            )
            b
    , emptyDone =
        D.decode
            (D.loop ( 3, [] )
                (\( n, acc ) ->
                    if n <= 0 then
                        D.succeed (D.Done [])

                    else
                        D.map (\x -> D.Loop ( n - 1, x :: acc )) D.unsignedInt8
                )
            )
            b
    , stringItem =
        D.decode
            (D.loop ( 3, [] )
                (\( n, acc ) ->
                    if n <= 0 then
                        D.succeed (D.Done acc)

                    else
                        D.map (\x -> D.Loop ( n - 1, x :: acc )) (D.string 3)
                )
            )
            b
    , noMap =
        D.decode
            (D.loop ( 3, [] )
                (\( n, acc ) ->
                    if n <= 0 then
                        D.succeed (D.Done acc)

                    else
                        D.succeed (D.Loop ( n - 1, acc ))
                )
            )
            b
    , computedCount =
        D.decode
            (D.loop ( k + 1, [] )
                (\( n, acc ) ->
                    if n <= 0 then
                        D.succeed (D.Done acc)

                    else
                        D.map (\x -> D.Loop ( n - 1, x :: acc )) D.unsignedInt8
                )
            )
            b
    , opaqueState =
        D.decode
            (D.loop ( 3, [] )
                (\( n, acc ) ->
                    if n <= 0 then
                        D.succeed (D.Done acc)

                    else
                        D.map (\x -> D.Loop (pair n x acc)) D.unsignedInt8
                )
            )
            b
    , extraDestruct =
        D.decode
            (D.loop ( 3, [] )
                (\( n, acc ) ->
                    let
                        ( p, q ) =
                            pair n 0 acc
                    in
                    if n <= 0 then
                        D.succeed (D.Done q)

                    else
                        D.map (\x -> D.Loop ( n - 1, x :: acc )) D.unsignedInt8
                )
            )
            b
    , firstOfState =
        D.decode
            (D.loop ( 3, [] )
                (\st ->
                    if Tuple.first st <= 0 then
                        D.succeed (D.Done (Tuple.second st))

                    else
                        D.map (\x -> D.Loop ( Tuple.first st - 1, x :: Tuple.second st )) D.unsignedInt8
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
