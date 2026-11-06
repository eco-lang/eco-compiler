module CovBytesFusionEncodePartialApplicationThroughLetTest exposing (..)

{-| A let-bound partial application `Bytes.Encode.unsignedInt16 BE`, completed inside a
`Bytes.Encode.sequence`, compiles.

`testValue` is a function and is never applied, so this checks that the program compiles
and that `Debug.log` prints the function as `<function>`, as Elm 0.19.1 does; no decoder or
encoder here is run on any input.

## eco

Exercises the bytes-fusion recognisers in
`compiler/src/Compiler/GenerateMlir/BytesFusion/` (an encoder reached through a let-bound
partial application). From the catalogue
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


testValue x =
    let
        w =
            E.unsignedInt16 BE
    in
    E.encode (E.sequence [ w x, E.unsignedInt8 x ])


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
