module CovBytesFusionDecodeLoopsWhosePartsAreParametersTest exposing (..)

{-| Decode loops whose parts are parameters.

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


testValue step g le mk done r b =
    { namedStep = D.decode (D.loop ( 3, [] ) step) b
    , sentinelInit =
        D.decode
            (D.loop [ 1 ]
                (\acc ->
                    D.andThen
                        (\x ->
                            if x == 0 then
                                D.succeed (D.Done acc)

                            else
                                D.succeed (D.Loop (x :: acc))
                        )
                        D.unsignedInt8
                )
            )
            b
    , thenNotSucceed =
        D.decode
            (D.loop ( 3, [] )
                (\( n, acc ) ->
                    if n <= 0 then
                        g (D.Done acc)

                    else
                        D.map (\x -> D.Loop ( n - 1, x :: acc )) D.unsignedInt8
                )
            )
            b
    , condThroughLocal =
        D.decode
            (D.loop ( 3, [] )
                (\( n, acc ) ->
                    if le n 0 then
                        D.succeed (D.Done acc)

                    else
                        D.map (\x -> D.Loop ( n - 1, x :: acc )) D.unsignedInt8
                )
            )
            b
    , mapFnNotLambda =
        D.decode
            (D.loop ( 3, [] )
                (\( n, acc ) ->
                    if n <= 0 then
                        D.succeed (D.Done acc)

                    else
                        D.map (mk n acc) D.unsignedInt8
                )
            )
            b
    , doneNotCtor =
        D.decode
            (D.loop ( 3, [] )
                (\( n, acc ) ->
                    if n <= 0 then
                        D.succeed done

                    else
                        D.map (\x -> D.Loop ( n - 1, x :: acc )) D.unsignedInt8
                )
            )
            b
    , recordDestruct =
        D.decode
            (D.loop ( 3, [] )
                (\( n, acc ) ->
                    let
                        { fx } =
                            r
                    in
                    if n <= fx then
                        D.succeed (D.Done acc)

                    else
                        D.map (\x -> D.Loop ( n - 1, x :: acc )) D.unsignedInt8
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
