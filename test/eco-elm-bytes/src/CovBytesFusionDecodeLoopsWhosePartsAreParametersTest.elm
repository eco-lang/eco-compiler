module CovBytesFusionDecodeLoopsWhosePartsAreParametersTest exposing (..)

{-| `Bytes.Decode.loop`s whose step, stop test, or result is supplied by a parameter compile.

`namedStep` passes the parameter `step` as the whole step function; `sentinelInit` reads
unsigned bytes until a 0, starting from `[ 1 ]`; `thenNotSucceed` finishes through the
parameter `g` instead of `succeed`; `condThroughLocal` stops on the parameter `le n 0`;
`mapFnNotLambda` maps with `mk n acc`; `doneNotCtor` finishes with `succeed done`, a
parameter rather than a `Done` value; `recordDestruct` stops on `n <= fx`, with `fx`
destructured in a `let` from the record parameter `r`.

`testValue` is a function and is never applied, so this checks that the program compiles
and that `Debug.log` prints the function as `<function>`, as Elm 0.19.1 does; no decoder or
encoder here is run on any input.

## eco

Exercises the bytes-fusion recognisers in
`compiler/src/Compiler/GenerateMlir/BytesFusion/` (loops whose parts are parameters, which
`reifyLoop` in `compiler/src/Compiler/GenerateMlir/BytesFusion/Reify.elm` cannot see
through). From the catalogue `compiler/tests/SourceIR/CovBytesFusionCases.elm`, which
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


testValue step g le mk done r b =
    { namedStep = D.decode (D.loop ( 3, [] ) step) b
    , sentinelInit =
        D.decode
            (D.loop [ 1 ]
                (\acc ->
                    D.andThen
                        (\x ->
                            if x == 0 then
                                D.succeed (D.Done acc)

                            else
                                D.succeed (D.Loop (x :: acc))
                        )
                        D.unsignedInt8
                )
            )
            b
    , thenNotSucceed =
        D.decode
            (D.loop ( 3, [] )
                (\( n, acc ) ->
                    if n <= 0 then
                        g (D.Done acc)

                    else
                        D.map (\x -> D.Loop ( n - 1, x :: acc )) D.unsignedInt8
                )
            )
            b
    , condThroughLocal =
        D.decode
            (D.loop ( 3, [] )
                (\( n, acc ) ->
                    if le n 0 then
                        D.succeed (D.Done acc)

                    else
                        D.map (\x -> D.Loop ( n - 1, x :: acc )) D.unsignedInt8
                )
            )
            b
    , mapFnNotLambda =
        D.decode
            (D.loop ( 3, [] )
                (\( n, acc ) ->
                    if n <= 0 then
                        D.succeed (D.Done acc)

                    else
                        D.map (mk n acc) D.unsignedInt8
                )
            )
            b
    , doneNotCtor =
        D.decode
            (D.loop ( 3, [] )
                (\( n, acc ) ->
                    if n <= 0 then
                        D.succeed done

                    else
                        D.map (\x -> D.Loop ( n - 1, x :: acc )) D.unsignedInt8
                )
            )
            b
    , recordDestruct =
        D.decode
            (D.loop ( 3, [] )
                (\( n, acc ) ->
                    let
                        { fx } =
                            r
                    in
                    if n <= fx then
                        D.succeed (D.Done acc)

                    else
                        D.map (\x -> D.Loop ( n - 1, x :: acc )) D.unsignedInt8
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
