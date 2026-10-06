module PolyLetTailRecTwoTypesTest exposing (main)

{-| BUG PIN (plans/staging-honesty-and-production-test-pipeline.md §4): a
let-bound, polymorphic, tail-recursive local function used at two types.

Under the production monomorphizer (the solver engine) the second
specialization's recursive call names `foldl$1`, which is not in scope, and the
compile crashes with "lookupVar: unbound variable foldl$1". The substitution
engine (bootstrap Stage 5) compiles it. The elm-test twin is the "Poly let-bound
multi-specialization is closed" failure (SourceIR.SpecializePolyLetCases,
"tail-recursive foldl at two types").
-}

-- CHECK: r: (6,2)

import Html exposing (text)


main =
    let
        foldl f acc xs =
            case xs of
                [] ->
                    acc

                x :: rest ->
                    foldl f (f x acc) rest

        _ =
            Debug.log "r" ( foldl (\x acc -> x + acc) 0 [ 1, 2, 3 ], foldl (\_ acc -> acc + 1) 0 [ "a", "b" ] )
    in
    text "done"
