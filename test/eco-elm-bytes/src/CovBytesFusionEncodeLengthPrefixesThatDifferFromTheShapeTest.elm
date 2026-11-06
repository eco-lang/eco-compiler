module CovBytesFusionEncodeLengthPrefixesThatDifferFromTheShapeTest exposing (..)

{-| Encoders that each vary one part of a length-prefixed byte list compile.

The common form is `sequence (unsignedInt32 BE (List.length xs) :: List.map (\x -> unsignedInt8 x) xs)`.
The fields vary it as follows: `otherList` takes the length of `ys`; `varEndian` takes the
endianness from the parameter `e`; `u16Header` and `u8Header` use a 16-bit and an 8-bit
length; `absHeader` writes `abs k`; `litHeader` writes the literal 3; `litList` uses the
literal list `[ 1, 2 ]` throughout; `notMap` reverses the mapped list; `externFn` maps
`unsignedInt8` itself rather than a lambda.

`testValue` is a function and is never applied, so this checks that the program compiles
and that `Debug.log` prints the function as `<function>`, as Elm 0.19.1 does; no decoder or
encoder here is run on any input.

## eco

Exercises the bytes-fusion recognisers in
`compiler/src/Compiler/GenerateMlir/BytesFusion/` (near misses of the length-prefixed list
shape the encoder side recognises). From the catalogue
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


testValue e k xs ys =
    { otherList = E.encode (E.sequence (E.unsignedInt32 BE (List.length ys) :: List.map (\x -> E.unsignedInt8 x) xs))
    , varEndian = E.encode (E.sequence (E.unsignedInt32 e (List.length xs) :: List.map (\x -> E.unsignedInt8 x) xs))
    , u16Header = E.encode (E.sequence (E.unsignedInt16 BE (List.length xs) :: List.map (\x -> E.unsignedInt8 x) xs))
    , u8Header = E.encode (E.sequence (E.unsignedInt8 (List.length xs) :: List.map (\x -> E.unsignedInt8 x) xs))
    , absHeader = E.encode (E.sequence (E.unsignedInt32 BE (abs k) :: List.map (\x -> E.unsignedInt8 x) xs))
    , litHeader = E.encode (E.sequence (E.unsignedInt32 BE 3 :: List.map (\x -> E.unsignedInt8 x) xs))
    , litList = E.encode (E.sequence (E.unsignedInt32 BE (List.length [ 1, 2 ]) :: List.map (\x -> E.unsignedInt8 x) [ 1, 2 ]))
    , notMap = E.encode (E.sequence (E.unsignedInt32 BE (List.length xs) :: List.reverse (List.map (\x -> E.unsignedInt8 x) xs)))
    , externFn = E.encode (E.sequence (E.unsignedInt32 BE (List.length xs) :: List.map E.unsignedInt8 xs))
    }


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
