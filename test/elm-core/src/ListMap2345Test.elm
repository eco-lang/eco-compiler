module ListMap2345Test exposing (main)

{-| `List.map2` and `List.map3` combine lists element by element.

`List.map2 (+)` adds two three-element lists, and `List.map3` sums three. `List.map4` and `List.map5` are not tested, despite the module name.

-}

-- CHECK: map2_result: [5,7,9]
-- CHECK: map3_result: [12,15,18]

import Html exposing (text)

main =
    let
        _ = Debug.log "map2_result" (List.map2 (+) [1, 2, 3] [4, 5, 6])
        _ = Debug.log "map3_result" (List.map3 (\a b c -> a + b + c) [1, 2, 3] [4, 5, 6] [7, 8, 9])
    in
    text "done"
