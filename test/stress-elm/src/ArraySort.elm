module ArraySort exposing (main)

-- CHECK: result: True

import Array exposing (Array)
import Html exposing (text)


n : Int
n =
    1000


m : Int
m =
    1000


reverse : Array a -> Array a
reverse arr =
    Array.foldl Array.push Array.empty arr


sortArray : Array comparable -> Array comparable
sortArray arr =
    arr |> Array.toList |> List.sort |> Array.fromList


loop : Array Int -> Int -> Bool -> Bool
loop sorted count ok =
    if count <= 0 then
        ok
    else
        let
            reversed =
                reverse sorted

            reSorted =
                sortArray reversed
        in
        loop reSorted (count - 1) (ok && reSorted == sorted)


main =
    let
        sorted =
            Array.initialize m (\i -> i + 1)

        result =
            loop sorted n True

        _ =
            Debug.log "result" result
    in
    text "done"
