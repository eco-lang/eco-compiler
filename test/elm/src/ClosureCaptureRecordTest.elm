module ClosureCaptureRecordTest exposing (main)

{-| A lambda returned from a function can use a captured record's fields, or the
elements of a captured tuple bound by a `case` pattern.

`closureFromRecord { x = 1, y = 2 }` and `closureFromTuple ( 1, 2 )` each
return a function adding 3 to its argument, so applied to 3 each logs 6.

-}

-- CHECK: rec: 6
-- CHECK: tup: 6

import Html exposing (text)


closureFromRecord : { x : Int, y : Int } -> Int -> Int
closureFromRecord rec =
    \n -> rec.x + rec.y + n


closureFromTuple : (Int, Int) -> Int -> Int
closureFromTuple pair =
    case pair of
        (a, b) -> \n -> a + b + n


main =
    let
        _ = Debug.log "rec" (closureFromRecord { x = 1, y = 2 } 3)
        _ = Debug.log "tup" (closureFromTuple (1, 2) 3)
    in
    text "done"
