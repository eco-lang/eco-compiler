module CoreIssue988NanEqualityReferenceTest exposing (main)

{-| Structural equality of values containing NaN depends on reference identity.

<https://github.com/elm/core/issues/988>

Elm 0.19.1 says `nan1 == nan1` is True (a reference shortcut) but `nan1 == nan2` is False for two
structurally identical lists `[ 0/0 ]`. Equality must not depend on whether the two operands are
the same object, so both comparisons must give the same answer.

-}

-- CHECK: same answer: True

import Html exposing (text)


nan1 : List Float
nan1 =
    [ 0 / 0 ]


nan2 : List Float
nan2 =
    [ 0 / 0 ]


main =
    let
        _ =
            Debug.log "same answer" ((nan1 == nan1) == (nan1 == nan2))
    in
    text "done"
