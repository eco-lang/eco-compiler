module CovBytesFusionDecodeCountLoopsOfEveryIntegerWidthTest exposing (..)

{-| `Bytes.Decode.loop`s that count down from 2 reading big-endian signed 16-bit, little-endian
unsigned 32-bit and big-endian signed 32-bit integers, and one that reads signed 8-bit
integers until a 0, compile.

Each loop conses the items it reads (all but the terminating 0, for the last) onto its
accumulator and finishes with that list, not reversed. `testValue` is a function and is never applied, so this checks that the program compiles
and that `Debug.log` prints the function as `<function>`, as Elm 0.19.1 does; no decoder or
encoder here is run on any input.

## eco

Exercises the bytes-fusion recognisers in
`compiler/src/Compiler/GenerateMlir/BytesFusion/` (count and sentinel loops of `reifyLoop`
in `compiler/src/Compiler/GenerateMlir/BytesFusion/Reify.elm` at each integer width). From
the catalogue `compiler/tests/SourceIR/CovBytesFusionCases.elm`, which drives the compiler
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
