module LetNumberContainerDualTest exposing (main)

{-| One unannotated `let`-bound tuple of number literals is used both as Ints and as
Floats.

Elm generalises the binding `t = ( 30, 40 )`, so `Tuple.first t + 1` uses it at
`Int` (31) and `Tuple.first t * 1.5` uses it at `Float` (rounded, 45).

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
