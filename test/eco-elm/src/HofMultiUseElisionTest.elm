module HofMultiUseElisionTest exposing (main)

{-| A let-bound lambda capturing a value and called twice with different arguments returns the right result from each call.

With `c = 5`, `f = \x -> x * 10 + c`, so `f 1 + f 2` = 15 + 25 = 40.

## eco

Exercises step H4.1 of the HOF-elimination work (plans/hof-elimination-closure-alloc-reduction.md):
a let-bound capturing lambda applied twice at saturated sites. The front-end
inliner (compiler/src/Compiler/MonoOpt/InlineSimplify.elm) leaves multi-use
closures alone because forwarding would duplicate the body; instead the
multi-use pattern in runtime/src/codegen/Passes/EcoPAPSimplify.cpp elides the
`papCreate` and rewrites both applications to direct calls.

There is no CHECK-MLIR-NOT here: the text MLIR dump is front-end output, taken
before EcoPAPSimplify runs, so the `papCreate` is still visible in it. The
structural checks live in test/codegen/pap_simplify_multi_use_elision.mlir and
its siblings; this test pins end-to-end behaviour through the real pipeline.

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
