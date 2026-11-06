module FnDevirtInlineTest exposing (main)

{-| A function passed as an argument and called inside a `Bytes.Encode.sequence` list literal gives an encoding of the expected width.

`build` takes the encoder-producing function as a parameter, `f`, and calls it twice
inside the list given to `BE.sequence`, around a literal `unsignedInt8 99`. With
`sectionOf`, which encodes one byte, the result is three bytes wide.

## eco

Exercises function-value devirtualization together with Bytes encoder fusion.
With `ECO_MONO_LSS_DEVIRT_FN=1` the call `f n` carries the singleton lambda set
for `sectionOf`, is devirtualized to a direct call and then inlined, which
plants a `mono_inline_N` let inside the `BE.sequence` element list. The
BytesFusion reifier (compiler/src/Compiler/GenerateMlir/BytesFusion) walks past
that let; before the fix the leftover reference crashed MLIR emission with
`lookupVar: unbound variable mono_inline_N`. The walked-past bindings are now
resolved at the fused-emit boundary in
compiler/src/Compiler/GenerateMlir/Expr.elm (`resolveFusedLets`).

The program must print the same answer with the flag on or off.

-}

-- CHECK: result: 3

import Bytes exposing (Bytes)
import Bytes.Encode as BE
import Html exposing (text)


sectionOf : Int -> BE.Encoder
sectionOf n =
    BE.unsignedInt8 (n + 1)


build : (Int -> BE.Encoder) -> Int -> Bytes
build f n =
    BE.encode
        (BE.sequence
            [ f n
            , BE.unsignedInt8 99
            , f (n + 40)
            ]
        )


main =
    let
        _ =
            Debug.log "result" (Bytes.width (build sectionOf 5))
    in
    text "done"
