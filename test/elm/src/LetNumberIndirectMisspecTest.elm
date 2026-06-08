module LetNumberIndirectMisspecTest exposing (main)

{-| Regression test (native/AOT backend): the let-bound-`number`
mis-specialization (see `LetNumberFloatMulTest`) also fires when the Float use
of the `number` is reached *indirectly*. Depending on how the value is routed,
this surfaces as either a kernel-signature-mismatch crash or an invalid-MLIR
native-lowering error (`eco.float.mul`/`llvm.call` operand `i64` vs `f64`):

  - `dual`     : the binding is used at both Int and Float in the same body
  - `identity` : the binding is laundered through `identity` before the Float op
  - `foldl`    : the binding is the Float seed of `List.foldl (+)`
  - `topfn`    : the binding is passed to a top-level Float function
  - `capture`  : the binding is captured by a closure used at Float

All correct outputs are shown below; today the module fails to build.

-}

-- CHECK: dual: (31, 45)
-- CHECK: identity: 45
-- CHECK: foldl: 4
-- CHECK: topfn: 45
-- CHECK: capture: 75

import Html exposing (text)


floatFn : Float -> Float
floatFn x =
    x * 1.5


main =
    let
        dual =
            let
                n =
                    30
            in
            ( n + 1, round (1.5 * n) )

        identityN =
            let
                n =
                    30
            in
            round (identity n * 1.5)

        foldlN =
            let
                acc0 =
                    0
            in
            round (List.foldl (+) acc0 [ 1.5, 2.5 ])

        topfnN =
            let
                n =
                    30
            in
            round (floatFn n)

        captureN =
            let
                k =
                    30
            in
            round ((\x -> x * k) 2.5)

        _ =
            Debug.log "dual" dual

        _ =
            Debug.log "identity" identityN

        _ =
            Debug.log "foldl" foldlN

        _ =
            Debug.log "topfn" topfnN

        _ =
            Debug.log "capture" captureN
    in
    text "done"
