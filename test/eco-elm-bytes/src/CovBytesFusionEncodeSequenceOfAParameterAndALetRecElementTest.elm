module CovBytesFusionEncodeSequenceOfAParameterAndALetRecElementTest exposing (..)

{-| `Bytes.Encode.sequence` applied to a parameter list, and to a list literal whose first
element is a `let` defining a recursive local function, compiles.

The local function `go` returns 0 for every argument.

`testValue` is a function and is never applied, so this checks that the program compiles
and that `Debug.log` prints the function as `<function>`, as Elm 0.19.1 does; no decoder or
encoder here is run on any input.

## eco

Exercises the bytes-fusion recognisers in
`compiler/src/Compiler/GenerateMlir/BytesFusion/` (`sequence` over lists the recogniser
cannot unfold). From the catalogue `compiler/tests/SourceIR/CovBytesFusionCases.elm`,
which drives the compiler front-end tests, with a `main` that logs its `testValue`; the
CHECK lines are what Elm 0.19.1 prints. The test only requires that compilation succeeds
whether or not fusion fires.

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


testValue encs x =
    ( E.encode (E.sequence encs)
    , E.encode
        (E.sequence
            [ let
                go n =
                    if n <= 0 then
                        0

                    else
                        go (n - 1)
              in
              E.unsignedInt8 (go x)
            , E.unsignedInt8 x
            ]
        )
    )


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
