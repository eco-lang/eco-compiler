module CovBytesFusionDecodeSentinelLoopsThatDifferFromTheIdiomTest exposing (..)

{-| Eleven `Bytes.Decode.loop`s that each vary a read-until-zero loop compile.

The common form starts from an empty list and, through `andThen`, finishes with `Done acc`
when the item read is 0, and otherwise continues with `Loop (x :: acc)`. The item decoder
differs between fields; beyond that, the fields vary it as follows: `noAndThen` finishes at once without reading; `namedCallback` uses the
parameter `g acc` as the callback; `noIf` always finishes; `gtCond` stops on `x > 0`;
`otherOperand` tests the parameter `c` instead of the item; `oneArgCond` stops on the
parameter `f x`; `loopWithoutCons` drops each item; `elseFails` uses `Bytes.Decode.fail`
instead of continuing; `elseDone` finishes in both branches; `floatItem` and `float64Item`
read 32-bit and 64-bit floats.

`testValue` is a function and is never applied, so this checks that the program compiles
and that `Debug.log` prints the function as `<function>`, as Elm 0.19.1 does; no decoder or
encoder here is run on any input.

## eco

Exercises the bytes-fusion recognisers in
`compiler/src/Compiler/GenerateMlir/BytesFusion/` (sentinel-loop near misses that
`reifyLoop` in `compiler/src/Compiler/GenerateMlir/BytesFusion/Reify.elm` must decline).
From the catalogue `compiler/tests/SourceIR/CovBytesFusionCases.elm`, which drives the
compiler front-end tests, with a `main` that logs its `testValue`; the CHECK lines are
what Elm 0.19.1 prints. The test only requires that compilation succeeds whether or not
fusion fires.

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


testValue f g c b =
    { noAndThen =
        D.decode (D.loop [] (\acc -> D.succeed (D.Done acc))) b
    , namedCallback =
        D.decode (D.loop [] (\acc -> D.andThen (g acc) D.unsignedInt8)) b
    , noIf =
        D.decode (D.loop [] (\acc -> D.andThen (\x -> D.succeed (D.Done acc)) D.unsignedInt8)) b
    , gtCond =
        D.decode
            (D.loop []
                (\acc ->
                    D.andThen
                        (\x ->
                            if x > 0 then
                                D.succeed (D.Done acc)

                            else
                                D.succeed (D.Loop (x :: acc))
                        )
                        D.unsignedInt8
                )
            )
            b
    , otherOperand =
        D.decode
            (D.loop []
                (\acc ->
                    D.andThen
                        (\x ->
                            if c == 0 then
                                D.succeed (D.Done acc)

                            else
                                D.succeed (D.Loop (x :: acc))
                        )
                        D.unsignedInt8
                )
            )
            b
    , oneArgCond =
        D.decode
            (D.loop []
                (\acc ->
                    D.andThen
                        (\x ->
                            if f x then
                                D.succeed (D.Done acc)

                            else
                                D.succeed (D.Loop (x :: acc))
                        )
                        D.signedInt8
                )
            )
            b
    , loopWithoutCons =
        D.decode
            (D.loop []
                (\acc ->
                    D.andThen
                        (\x ->
                            if x == 0 then
                                D.succeed (D.Done acc)

                            else
                                D.succeed (D.Loop acc)
                        )
                        (D.signedInt16 LE)
                )
            )
            b
    , elseFails =
        D.decode
            (D.loop []
                (\acc ->
                    D.andThen
                        (\x ->
                            if x == 0 then
                                D.succeed (D.Done acc)

                            else
                                D.fail
                        )
                        (D.unsignedInt32 LE)
                )
            )
            b
    , elseDone =
        D.decode
            (D.loop []
                (\acc ->
                    D.andThen
                        (\x ->
                            if x == 0 then
                                D.succeed (D.Done acc)

                            else
                                D.succeed (D.Done (x :: acc))
                        )
                        (D.signedInt32 BE)
                )
            )
            b
    , floatItem =
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
                        (D.float32 BE)
                )
            )
            b
    , float64Item =
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
                        (D.float64 LE)
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
