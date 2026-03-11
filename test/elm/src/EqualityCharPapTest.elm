module EqualityCharPapTest exposing (main)

{-| Test that using (==) as a function value on Char works correctly.
Char uses i16 ABI, so kernel PAP must use AllBoxed (!eco.value).
-}

-- CHECK: filtered: ['a', 'a']

import Html exposing (text)


main =
    let
        eq = (==)
        filtered = List.filter (eq 'a') ['a', 'b', 'a', 'c']
        _ = Debug.log "filtered" filtered
    in
    text "done"
