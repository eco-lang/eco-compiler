module EqualityFloatPapTest exposing (main)

{-| Test that using (==) as a function value on Float works correctly.
Float uses f64 ABI, so kernel PAP must use AllBoxed (!eco.value).
-}

-- CHECK: filtered: [1.5, 1.5]

import Html exposing (text)


main =
    let
        eq = (==)
        filtered = List.filter (eq 1.5) [1.0, 1.5, 2.0, 1.5]
        _ = Debug.log "filtered" filtered
    in
    text "done"
