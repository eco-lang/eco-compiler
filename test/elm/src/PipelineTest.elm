module PipelineTest exposing (main)

{-| Test pipeline operators.
-}

-- CHECK: pipe1: 12
-- CHECK: pipe2: [2,4,6]
-- CHECK: backpipe: 10

import Html exposing (text)


double x = x * 2
addOne x = x + 1


main =
    let
        _ = Debug.log "pipe1" (5 |> double |> addOne |> addOne)
        _ = Debug.log "pipe2" ([1, 2, 3] |> List.map double)
        _ = Debug.log "backpipe" (double <| addOne <| 4)
    in
    text "done"
