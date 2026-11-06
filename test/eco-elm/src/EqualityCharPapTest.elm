module EqualityCharPapTest exposing (main)

{-| `(==)` bound to a variable and partially applied to a `Char` works as a
predicate for `List.filter`.

`eq` is `(==)` itself, and `List.filter (eq 'a')` keeps the two `'a'` elements
of `['a', 'b', 'a', 'c']`.

## eco

`Char` uses an `i16` ABI, but a kernel partial application must take every argument boxed: the PAP of `Elm_Kernel_Utils_equal` must use the all-`!eco.value` ABI, not the `Char` one.

-}

-- CHECK: filtered: ['a','a']

import Html exposing (text)


main =
    let
        eq = (==)
        filtered = List.filter (eq 'a') ['a', 'b', 'a', 'c']
        _ = Debug.log "filtered" filtered
    in
    text "done"
