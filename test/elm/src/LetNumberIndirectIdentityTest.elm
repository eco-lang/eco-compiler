module LetNumberIndirectIdentityTest exposing (main)

{-| Regression test (native/AOT backend): the let-bound-`number`
mis-specialization (see `LetNumberFloatMulTest`) reached when the `number` is
laundered through `identity` before the `Float` multiply. Correct: 1.5*30 = 45.

-}

-- CHECK: identity: 45

import Html exposing (text)


main =
    let
        identityN =
            let
                n =
                    30
            in
            round (identity n * 1.5)

        _ =
            Debug.log "identity" identityN
    in
    text "done"
