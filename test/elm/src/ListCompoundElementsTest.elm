module ListCompoundElementsTest exposing (main)

{-| Test lists containing compound elements: tuples and records. -}

-- CHECK: tupleLen: 3
-- CHECK: firstTuple: (1,"a")
-- CHECK: recordLen: 2
-- CHECK: firstX: 10
-- CHECK: sumX: 30

import Html exposing (text)


main =
    let
        tuples = [ ( 1, "a" ), ( 2, "b" ), ( 3, "c" ) ]
        _ = Debug.log "tupleLen" (List.length tuples)
        _ = Debug.log "firstTuple" (case List.head tuples of
            Just t -> t
            Nothing -> ( 0, "" ))
        records = [ { x = 10, y = "hello" }, { x = 20, y = "world" } ]
        _ = Debug.log "recordLen" (List.length records)
        firstX =
            case List.head records of
                Just r ->
                    r.x

                Nothing ->
                    0
        _ = Debug.log "firstX" firstX
        _ = Debug.log "sumX" (List.foldl (\r acc -> acc + r.x) 0 records)
    in
    text "done"
