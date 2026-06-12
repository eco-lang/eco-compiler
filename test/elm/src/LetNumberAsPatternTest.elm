module LetNumberAsPatternTest exposing (main)

{-| Probe: tuple as-pattern (`( a, b ) as whole`). One slot is used at `Float`
(`a * 1.5`) while the WHOLE tuple is also consumed, so the slot demand and the
whole-value materialisation must agree. Since `a` forces `Float`, `whole` is
`( Float, Float )`. Correct: round (30*1.5) + round (30+40) = 45 + 70 = 115.
-}

-- CHECK: aspat: 115

import Html exposing (text)


main =
    let
        result =
            case ( 30, 40 ) of
                (( a, _ ) as whole) ->
                    round (a * 1.5) + round (Tuple.first whole + Tuple.second whole)

        _ =
            Debug.log "aspat" result
    in
    text "done"
