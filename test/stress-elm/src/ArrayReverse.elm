module ArrayReverse exposing (main)

-- CHECK: roundtrip: True

import Array exposing (Array)
import Html exposing (text)


initialArray : Array Int
initialArray =
    Array.initialize 1000 (\i -> i + 1)


reverse : Array a -> Array a
reverse arr =
    Array.foldl Array.push Array.empty arr


reverseNTimes : Int -> Array a -> Array a
reverseNTimes count arr =
    if count <= 0 then
        arr
    else
        reverseNTimes (count - 1) (reverse arr)


main =
    let
        start =
            initialArray

        finished =
            reverseNTimes 1000 start

        _ =
            Debug.log "roundtrip" (start == finished)
    in
    text "done"
