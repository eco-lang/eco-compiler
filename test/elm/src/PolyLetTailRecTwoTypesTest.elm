module PolyLetTailRecTwoTypesTest exposing (main)

{-| A let-bound, polymorphic, tail-recursive local function used at two types.

Each use needs its own copy of the loop: the solver emits `foldl` and
`foldl$1`, each a `MonoTailDef` whose self-calls name that copy. It used to emit
one `foldl` while the second use named `foldl$1`, and the compile crashed with
"lookupVar: unbound variable foldl$1" (MONO_011). The elm-test twin is the
"tail-recursive foldl at two types" case of SourceIR.SpecializePolyLetCases.
-}

-- CHECK: r: (6, 2)

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
