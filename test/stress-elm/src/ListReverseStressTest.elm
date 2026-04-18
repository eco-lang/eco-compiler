module ListReverseStressTest exposing (main)

-- CHECK: roundtrip: True

import Html exposing (text)


initialList : List Int
initialList =
    List.range 1 1000


reverseNTimes : Int -> List a -> List a
reverseNTimes n list =
    if n <= 0 then
        list
    else
        reverseNTimes (n - 1) (List.reverse list)


main =
    let
        start =
            initialList

        finished =
            reverseNTimes 1000 start

        _ =
            Debug.log "roundtrip" (start == finished)
    in
    text "done"
