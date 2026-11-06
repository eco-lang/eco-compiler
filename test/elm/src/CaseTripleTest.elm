module CaseTripleTest exposing (main)

{-| A case expression on a 3-tuple of `Int`s matches literal and wildcard
patterns in order, taking the first branch that fits.

The patterns are `(0, 0, 0)`, `(0, _, _)`, `(_, _, 0)` and a wildcard, and each
of the four inputs reaches a different one.

-}

-- CHECK: triple1: "all zero"
-- CHECK: triple2: "x zero"
-- CHECK: triple3: "z zero"
-- CHECK: triple4: "none zero"

import Html exposing (text)


describeTriple triple =
    case triple of
        (0, 0, 0) -> "all zero"
        (0, _, _) -> "x zero"
        (_, _, 0) -> "z zero"
        _ -> "none zero"


main =
    let
        _ = Debug.log "triple1" (describeTriple (0, 0, 0))
        _ = Debug.log "triple2" (describeTriple (0, 1, 2))
        _ = Debug.log "triple3" (describeTriple (1, 2, 0))
        _ = Debug.log "triple4" (describeTriple (1, 2, 3))
    in
    text "done"
