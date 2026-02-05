module LetSeparatedStagingTest exposing (main)

import Html exposing (text)

caseFunc : Int -> Int -> Int -> Int -> Int
caseFunc n k =
    case n of
        0 -> \a -> let y = a + k in \z -> y + z
        _ -> \a z -> a + z

main =
    let
        _ = Debug.log "result" (caseFunc 0 10 5 3)
    in
    text "done"
