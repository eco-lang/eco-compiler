module ClosureCaptureRecordTest exposing (main)

{-| Test closures capturing record fields and tuple elements. -}

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
