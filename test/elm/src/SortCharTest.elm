module SortCharTest exposing (main)

{-| `List.sort`, `List.sortBy`, `List.sortWith` on `List Char`.

    `Char` is unboxed as `u16`. The sort kernels re-box unboxed list heads as
    `Elm Int`, which corrupts the `Tag_Char` expected by the user comparator.
    This test pins the IEEE-correct / type-correct behavior.
-}

-- CHECK: sort: ['a', 'b', 'c']
-- CHECK: sortWith: ['x', 'y', 'z']
-- CHECK: reverse: ['c', 'b', 'a']
-- CHECK: sortByCode: ['A', 'Z', 'a', 'z']

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
