module LetNumberIndirectDualTest exposing (main)

{-| Regression test (native/AOT backend): the let-bound-`number`
mis-specialization (see `LetNumberFloatMulTest`) reached when the binding is used
at both an `Int`-defaulting position and a `Float` position in the same body. The
`Float` use (`1.5 * n`) must specialize `n` to `Float`; the `n + 1` use stays
`Float` too. Correct: ( 31, 45 ).

-}

-- CHECK: dual: (31, 45)

import Html exposing (text)


main =
    let
        dual =
            let
                n =
                    30
            in
            ( n + 1, round (1.5 * n) )

        _ =
            Debug.log "dual" dual
    in
    text "done"
