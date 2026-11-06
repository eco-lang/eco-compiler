module LetNumberCustomTriple3Test exposing (main)

{-| A single-constructor type whose three fields share one type variable, built from
number literals in an unannotated `let` and matched by `case` with every field used
as a Float: `round 45 + round 60 + round 75` gives 180.
-}

-- CHECK: tri3: 180

import Html exposing (text)


type Tri number
    = Tri number number number


main =
    let
        v =
            Tri 30 40 50

        result =
            case v of
                Tri a b c ->
                    round (a * 1.5) + round (b * 1.5) + round (c * 1.5)

        _ =
            Debug.log "tri3" result
    in
    text "done"
