module CaseTupleLiteralTest exposing (main)

{-| Test case on nested tuple with literal patterns. -}

-- CHECK: origin: "origin"
-- CHECK: xaxis: "x-axis"
-- CHECK: yaxis: "y-axis"
-- CHECK: unit: "unit"
-- CHECK: general: "general"

import Html exposing (text)


classify t =
    case t of
        (0, 0) -> "origin"
        (0, _) -> "y-axis"
        (_, 0) -> "x-axis"
        (1, 1) -> "unit"
        _ -> "general"


main =
    let
        _ = Debug.log "origin" (classify (0, 0))
        _ = Debug.log "xaxis" (classify (3, 0))
        _ = Debug.log "yaxis" (classify (0, 5))
        _ = Debug.log "unit" (classify (1, 1))
        _ = Debug.log "general" (classify (2, 3))
    in
    text "done"
