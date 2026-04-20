module FromArrayFloatListMapTest exposing (main)

{-| Array.fromList → Array.toList → List.map (+ 0.5). Verifies that Float
    element bits survive the Array → List conversion intact so that
    downstream `List.map` arithmetic produces the right numeric result.
-}

-- CHECK: result: [2, 3]
-- CHECK: match: True

import Array
import Html exposing (text)


main =
    let
        arr = Array.fromList [1.5, 2.5]
        result = List.map ((+) 0.5) (Array.toList arr)
        _ = Debug.log "result" result
        _ = Debug.log "match" (result == [2.0, 3.0])
    in
    text "done"
