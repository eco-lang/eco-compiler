module CovBytesFusionDecodeSentinelLoopsThatDifferFromTheIdiomTest exposing (..)

{-| Decode sentinel loops that differ from the idiom.

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


testValue f g c b =
    { noAndThen =
        D.decode (D.loop [] (\acc -> D.succeed (D.Done acc))) b
    , namedCallback =
        D.decode (D.loop [] (\acc -> D.andThen (g acc) D.unsignedInt8)) b
    , noIf =
        D.decode (D.loop [] (\acc -> D.andThen (\x -> D.succeed (D.Done acc)) D.unsignedInt8)) b
    , gtCond =
        D.decode
            (D.loop []
                (\acc ->
                    D.andThen
                        (\x ->
                            if x > 0 then
                                D.succeed (D.Done acc)

                            else
                                D.succeed (D.Loop (x :: acc))
                        )
                        D.unsignedInt8
                )
            )
            b
    , otherOperand =
        D.decode
            (D.loop []
                (\acc ->
                    D.andThen
                        (\x ->
                            if c == 0 then
                                D.succeed (D.Done acc)

                            else
                                D.succeed (D.Loop (x :: acc))
                        )
                        D.unsignedInt8
                )
            )
            b
    , oneArgCond =
        D.decode
            (D.loop []
                (\acc ->
                    D.andThen
                        (\x ->
                            if f x then
                                D.succeed (D.Done acc)

                            else
                                D.succeed (D.Loop (x :: acc))
                        )
                        D.signedInt8
                )
            )
            b
    , loopWithoutCons =
        D.decode
            (D.loop []
                (\acc ->
                    D.andThen
                        (\x ->
                            if x == 0 then
                                D.succeed (D.Done acc)

                            else
                                D.succeed (D.Loop acc)
                        )
                        (D.signedInt16 LE)
                )
            )
            b
    , elseFails =
        D.decode
            (D.loop []
                (\acc ->
                    D.andThen
                        (\x ->
                            if x == 0 then
                                D.succeed (D.Done acc)

                            else
                                D.fail
                        )
                        (D.unsignedInt32 LE)
                )
            )
            b
    , elseDone =
        D.decode
            (D.loop []
                (\acc ->
                    D.andThen
                        (\x ->
                            if x == 0 then
                                D.succeed (D.Done acc)

                            else
                                D.succeed (D.Done (x :: acc))
                        )
                        (D.signedInt32 BE)
                )
            )
            b
    , floatItem =
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
                        (D.float32 BE)
                )
            )
            b
    , float64Item =
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
                        (D.float64 LE)
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
