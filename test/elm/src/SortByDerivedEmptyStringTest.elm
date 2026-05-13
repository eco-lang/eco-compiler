module SortByDerivedEmptyStringTest exposing (main)

{-| `List.sortBy` with a key extractor that *produces* `""` for some
inputs (via `String.reverse ""` ≡ `""`). The constant is created by
the key function, not by the input — confirms that downstream allocator
calls don't depend on whether the constant was lexical or derived.
-}

-- CHECK: result: ["", "", "a", "ba"]

import Html exposing (text)


main =
    let
        result : List String
        result = List.sortBy String.reverse [ "", "ba", "a", "" ]

        _ = Debug.log "result" result
    in
    text "done"
