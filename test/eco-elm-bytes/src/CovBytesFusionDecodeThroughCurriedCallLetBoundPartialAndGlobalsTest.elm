module CovBytesFusionDecodeThroughCurriedCallLetBoundPartialAndGlobalsTest exposing (..)

{-| Decoders reached through a let-bound partial application, a top-level constant and a
top-level function compile.

Field `a` adds two unsigned bytes with `map2` written in place; `c` applies the let-bound
`rd = Bytes.Decode.unsignedInt16` to `BE`; `d` uses the top-level decoder `dec`; `e` applies
the top-level function `decE` to `LE`; `f` completes the let-bound partial application `rd2`
of `map2` with a signed byte decoder.

`testValue` is a function and is never applied, so this checks that the program compiles
and that `Debug.log` prints the function as `<function>`, as Elm 0.19.1 does; no decoder or
encoder here is run on any input.

## eco

Exercises the bytes-fusion recognisers in
`compiler/src/Compiler/GenerateMlir/BytesFusion/` (decoders reached through let-bound
partials and globals, which `compiler/src/Compiler/GenerateMlir/BytesFusion/Reify.elm`
resolves or declines). From the catalogue
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
    let
        rd =
            D.unsignedInt16

        rd2 =
            D.map2 (\x y -> x + y) D.unsignedInt8
    in
    { a = D.decode (D.map2 (\x y -> x + y) D.unsignedInt8 D.unsignedInt8) b
    , c = D.decode (rd BE) b
    , d = D.decode dec b
    , e = D.decode (decE LE) b
    , f = D.decode (rd2 D.signedInt8) b
    }


{-| Decodes an unsigned 16-bit integer with the given endianness.
-}
decE : Endianness -> D.Decoder Int
decE e =
    D.unsignedInt16 e


{-| Decodes an unsigned byte.
-}
dec : D.Decoder Int
dec =
    D.unsignedInt8


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
