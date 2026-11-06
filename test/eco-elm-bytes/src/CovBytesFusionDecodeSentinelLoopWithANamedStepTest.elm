module CovBytesFusionDecodeSentinelLoopWithANamedStepTest exposing (..)

{-| A `Bytes.Decode.loop` whose step is a top-level function, reading unsigned bytes until a 0,
compiles.

`testValue` is a function and is never applied, so this checks that the program compiles
and that `Debug.log` prints the function as `<function>`, as Elm 0.19.1 does; no decoder or
encoder here is run on any input.

## eco

Exercises the bytes-fusion recognisers in
`compiler/src/Compiler/GenerateMlir/BytesFusion/` (a sentinel loop whose step `reifyLoop`
in `compiler/src/Compiler/GenerateMlir/BytesFusion/Reify.elm` must resolve through a top-
level name). From the catalogue `compiler/tests/SourceIR/CovBytesFusionCases.elm`, which
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
    D.decode (D.loop [] step) b


{-| Reads one unsigned byte: finishes with the accumulator on 0, otherwise conses the byte and
continues.
-}
step : List Int -> D.Decoder (D.Step (List Int) (List Int))
step acc =
    D.andThen
        (\x ->
            if x == 0 then
                D.succeed (D.Done acc)

            else
                D.succeed (D.Loop (x :: acc))
        )
        D.unsignedInt8


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
