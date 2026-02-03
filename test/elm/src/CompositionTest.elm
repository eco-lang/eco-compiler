module CompositionTest exposing (main)

{-| Test function composition.
-}

-- CHECK: compose1: 20
-- CHECK: compose2: 11
-- CHECK: pipe1: 20

import Html exposing (text)


double x = x * 2
addOne x = x + 1


main =
    let
        -- (>>) left-to-right composition: first addOne, then double
        addOneThenDouble = addOne >> double
        -- (<<) right-to-left composition: first double, then addOne
        doubleThenAddOne = addOne << double
        _ = Debug.log "compose1" (addOneThenDouble 9)
        _ = Debug.log "compose2" (doubleThenAddOne 5)
        -- Pipe operator
        _ = Debug.log "pipe1" (9 |> addOne |> double)
    in
    text "done"
