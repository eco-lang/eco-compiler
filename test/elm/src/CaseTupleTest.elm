module CaseTupleTest exposing (main)

{-| A case expression on a pair of `Int`s matches literal and wildcard patterns
in order, taking the first branch that fits.

The patterns are `(0, 0)`, `(0, _)`, `(_, 0)` and a wildcard, and each of the
four inputs reaches a different one.

-}

-- CHECK: pair1: "both zero"
-- CHECK: pair2: "x is zero"
-- CHECK: pair3: "y is zero"
-- CHECK: pair4: "neither zero"

import Html exposing (text)


describePair pair =
    case pair of
        (0, 0) -> "both zero"
        (0, _) -> "x is zero"
        (_, 0) -> "y is zero"
        _ -> "neither zero"


main =
    let
        _ = Debug.log "pair1" (describePair (0, 0))
        _ = Debug.log "pair2" (describePair (0, 5))
        _ = Debug.log "pair3" (describePair (3, 0))
        _ = Debug.log "pair4" (describePair (1, 2))
    in
    text "done"
