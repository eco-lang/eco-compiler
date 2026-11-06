module CovBytesFusionEncodeWithEndiannessThatIsNotAConstructorTest exposing (..)

{-| Encoders whose endianness is a top-level constant or a parameter, rather than `BE` or `LE`
written at the call, compile.

`testValue` is a function and is never applied, so this checks that the program compiles
and that `Debug.log` prints the function as `<function>`, as Elm 0.19.1 does; no decoder or
encoder here is run on any input.

## eco

Exercises the bytes-fusion recognisers in
`compiler/src/Compiler/GenerateMlir/BytesFusion/` (endianness that is not a literal
`BE`/`LE` constructor). From the catalogue
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


testValue e x =
    E.encode (E.sequence [ E.unsignedInt16 big x, E.unsignedInt16 e x, E.float64 e 1.0 ])


{-| Big-endian, as a top-level constant.
-}
big : Endianness
big =
    BE


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
