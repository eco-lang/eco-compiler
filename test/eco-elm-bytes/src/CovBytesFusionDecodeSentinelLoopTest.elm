module CovBytesFusionDecodeSentinelLoopTest exposing (..)

{-| A `Bytes.Decode.loop` that reads big-endian unsigned 16-bit integers until one is 0 and
finishes with the others in reading order compiles.

`testValue` is a function and is never applied, so this checks that the program compiles
and that `Debug.log` prints the function as `<function>`, as Elm 0.19.1 does; no decoder or
encoder here is run on any input.

## eco

Exercises the bytes-fusion recognisers in
`compiler/src/Compiler/GenerateMlir/BytesFusion/` (the sentinel-loop idiom of `reifyLoop`
in `compiler/src/Compiler/GenerateMlir/BytesFusion/Reify.elm`). From the catalogue
`compiler/tests/SourceIR/CovBytesFusionCases.elm`, which drives the compiler front-end
tests, with a `main` that logs its `testValue`; the CHECK lines are what Elm 0.19.1
prints. The test only requires that compilation succeeds whether or not fusion fires.

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
    D.decode
        (D.loop []
            (\acc ->
                D.andThen
                    (\byte ->
                        if 0 == byte then
                            D.succeed (D.Done (List.reverse acc))

                        else
                            D.succeed (D.Loop (byte :: acc))
                    )
                    (D.unsignedInt16 BE)
            )
        )
        b


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
