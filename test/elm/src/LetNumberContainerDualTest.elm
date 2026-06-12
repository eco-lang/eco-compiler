module LetNumberContainerDualTest exposing (main)

{-| Probe: a generalized let-bound tuple value (`t = ( 30, 40 )`) whose first slot
is projected at BOTH `Int` (`Tuple.first t + 1`) and `Float`
(`Tuple.first t * 1.5`). The same container binding must materialise an Int and a
Float instance — the container analogue of `LetNumberIndirectDualTest`. Correct:
intUse = 30 + 1 = 31 ; floatUse = round (30*1.5) = 45.
-}

-- CHECK: dual-int: 31
-- CHECK: dual-float: 45

import Html exposing (text)


main =
    let
        t =
            ( 30, 40 )

        intUse =
            Tuple.first t + 1

        floatUse =
            round (Tuple.first t * 1.5)

        _ =
            Debug.log "dual-int" intUse

        _ =
            Debug.log "dual-float" floatUse
    in
    text "done"
