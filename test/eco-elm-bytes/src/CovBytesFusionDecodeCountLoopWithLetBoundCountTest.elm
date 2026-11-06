module CovBytesFusionDecodeCountLoopWithLetBoundCountTest exposing (..)

{-| A `Bytes.Decode.loop` that counts down from a let-bound count of 4, reading one
little-endian unsigned 16-bit integer per step and finishing with the reversed list, compiles.

`testValue` is a function and is never applied, so this checks that the program compiles
and that `Debug.log` prints the function as `<function>`, as Elm 0.19.1 does; no decoder or
encoder here is run on any input.

## eco

Exercises the bytes-fusion recognisers in
`compiler/src/Compiler/GenerateMlir/BytesFusion/` (the count-loop idiom of `reifyLoop` in
`compiler/src/Compiler/GenerateMlir/BytesFusion/Reify.elm`, with the count reached through
a `let`). From the catalogue `compiler/tests/SourceIR/CovBytesFusionCases.elm`, which
drives the compiler front-end tests, with a `main` that logs its `testValue`; the CHECK
lines are what Elm 0.19.1 prints. The test only requires that compilation succeeds whether
or not fusion fires.

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
        count =
            4
    in
    D.decode
        (D.loop ( count, [] )
            (\( n, acc ) ->
                if n <= 0 then
                    D.succeed (D.Done (List.reverse acc))

                else
                    D.map (\x -> D.Loop ( n - 1, x :: acc )) (D.unsignedInt16 LE)
            )
        )
        b


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
