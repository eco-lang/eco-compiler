module CovBytesFusionDecodeCountLoopsThatDifferFromTheIdiomTest exposing (..)

{-| Thirteen `Bytes.Decode.loop`s that each vary a count-down loop compile.

The common form starts from a count of 3 and an empty list, finishes with `Done acc` when
`n <= 0`, and otherwise maps the item decoder to `Loop ( n - 1, x :: acc )`. The item decoder
differs between fields; beyond that, the fields vary it as follows: `nonEmptyAcc` starts from `[ 1 ]`; `ltCond` stops on `n < 1`; `oneArgCond`
stops on the parameter `f n`; `noDecrement` never lowers the count; `noCons` drops each item;
`doubleReverse` finishes with the list reversed twice; `emptyDone` finishes with `[]`;
`stringItem` reads 3-byte strings; `noMap` reads nothing and only counts down;
`computedCount` starts from `k + 1`; `opaqueState` builds the next state with the parameter
`pair`; `extraDestruct` destructures `pair n 0 acc` in a `let` and finishes with its second
part; `firstOfState` reads the state with `Tuple.first` and `Tuple.second`.

`testValue` is a function and is never applied, so this checks that the program compiles
and that `Debug.log` prints the function as `<function>`, as Elm 0.19.1 does; no decoder or
encoder here is run on any input.

## eco

Exercises the bytes-fusion recognisers in
`compiler/src/Compiler/GenerateMlir/BytesFusion/` (count-loop near misses that `reifyLoop`
in `compiler/src/Compiler/GenerateMlir/BytesFusion/Reify.elm` must decline). From the
catalogue `compiler/tests/SourceIR/CovBytesFusionCases.elm`, which drives the compiler
front-end tests, with a `main` that logs its `testValue`; the CHECK lines are what Elm
0.19.1 prints. The test only requires that compilation succeeds whether or not fusion
fires.

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
