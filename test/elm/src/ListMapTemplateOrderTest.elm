module ListMapTemplateOrderTest exposing (main)

{-| Checks that `List.map` with a callback that calls `Debug.log` logs the elements
from last to first.

elm/core defines `List.map` with `List.foldr`, which, on a list this short,
applies the callback to the last element first. Mapping
`\x -> Debug.log "m" x` over `["a", "b", "c", "d", "e"]` therefore logs `"e"`
through `"a"` in that order, and the mapped list keeps all five elements.

-}

-- CHECK: m: "e"
-- CHECK-NEXT: m: "d"
-- CHECK-NEXT: m: "c"
-- CHECK-NEXT: m: "b"
-- CHECK-NEXT: m: "a"
-- CHECK: len: 5

import Html exposing (text)


{-| Maps `Debug.log "m"` over `xs`, logging each element.
-}
logged : List String -> List String
logged xs =
    List.map (\x -> Debug.log "m" x) xs


main : Html.Html msg
main =
    let
        mapped =
            logged [ "a", "b", "c", "d", "e" ]

        _ =
            Debug.log "len" (List.length mapped)
    in
    text "done"
