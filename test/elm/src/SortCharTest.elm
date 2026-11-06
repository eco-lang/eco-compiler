module SortCharTest exposing (main)

{-| `List.sort`, `List.sortWith` and `List.sortBy` order a `List Char` correctly and return the elements as `Char` values.

The test checks four results:

  - `List.sort` puts `['c', 'a', 'b']` in order.
  - `List.sortWith compare` puts `['z', 'x', 'y']` in order.
  - `List.sortWith` with the comparison flipped sorts `['a', 'b', 'c']` into
    reverse order.
  - `List.sortBy Char.toCode` orders by character code, so the uppercase
    letters come before the lowercase ones: `['A','Z','a','z']`.

-}

-- CHECK: sort: ['a','b','c']
-- CHECK: sortWith: ['x','y','z']
-- CHECK: reverse: ['c','b','a']
-- CHECK: sortByCode: ['A','Z','a','z']

import Char
import Html exposing (text)


main =
    let
        _ = Debug.log "sort" (List.sort ['c', 'a', 'b'])
        _ = Debug.log "sortWith" (List.sortWith compare ['z', 'x', 'y'])
        _ = Debug.log "reverse" (List.sortWith (\a b -> compare b a) ['a', 'b', 'c'])
        _ = Debug.log "sortByCode" (List.sortBy Char.toCode ['a', 'Z', 'z', 'A'])
    in
    text "done"
