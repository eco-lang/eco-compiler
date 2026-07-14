module HofMultiUseElisionTest exposing (main)

{-| H4.1 (plans/hof-elimination-closure-alloc-reduction.md): a let-bound
capturing lambda applied TWICE at saturated ground sites. The front-end
inliner deliberately leaves multi-use closures alone (forwarding would
duplicate the body); the MLIR-level P4 pattern in EcoPAPSimplify elides the
papCreate and rewrites both applications to direct $cap calls.

NOTE: no CHECK-MLIR-NOT here — the text-MLIR dump is FRONT-END output,
before EcoPAPSimplify runs, so the papCreate is still visible there. The
structural pins live in test/codegen/pap_simplify_multi_use_*.mlir; this
test pins end-to-end behavior (compile, JIT through the pass, correct
results under the real pipeline).

Behavioral: c=5 → f 1 + f 2 = (10+5) + (20+5) = 40.

-}

-- CHECK: result: 40


import Html exposing (text)


compute : Int -> Int
compute c =
    let
        f =
            \x -> x * 10 + c
    in
    f 1 + f 2


main =
    let
        _ =
            Debug.log "result" (compute 5)
    in
    text "done"
