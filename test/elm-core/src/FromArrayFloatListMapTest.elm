module FromArrayFloatListMapTest exposing (main)

{-| Floating-point arithmetic in `List.map` works on a `List Float` taken out of an `Array` with `Array.toList`.

`[1.5, 2.5]` goes through `Array.fromList` and `Array.toList`, and adding 0.5 to each element gives `[2.0, 3.0]`.
-}

-- CHECK: result: [2,3]
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
