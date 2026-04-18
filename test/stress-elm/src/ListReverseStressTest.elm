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
            Debug.log "start-first-10" (List.take 10 start)

        _ =
            Debug.log "finished-first-10" (List.take 10 finished)

        _ =
            Debug.log "start-last-10" (List.drop 990 start)

        _ =
            Debug.log "finished-last-10" (List.drop 990 finished)

        _ =
            Debug.log "start-length" (List.length start)

        _ =
            Debug.log "finished-length" (List.length finished)

        _ =
            Debug.log "roundtrip" (start == finished)
    in
    text "done"
