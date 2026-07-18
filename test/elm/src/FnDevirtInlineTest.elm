module FnDevirtInlineTest exposing (main)

{-| E9.1 (plan §E9.1): fn-global devirtualization + the BytesFusion
walked-past-let seam.

`build` receives `sectionOf` as a VALUE; with `ECO_MONO_LSS_DEVIRT_FN=1`
the `f n` site carries the singleton {g|sectionOf}, devirtualizes to a
direct call, and the inliner inlines the tiny body — planting a
`mono_inline_N` let INSIDE the `BE.sequence` element list. BytesFusion's
reifier walks past that let; pre-fix, the residual reference crashed MLIR
emission with `lookupVar: unbound variable mono_inline_N` (reproduced at
self-compile scale in `Mlir.Bytecode.StreamEncode.assembleModule`). The
fix resolves walked-past bindings at the fused-emit boundary
(`Expr.bfExprCompiler`/`resolveFusedLets`).

Runs (and must print the same answer) with the flag on or off.

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
