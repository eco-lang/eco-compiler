module EqualityFloatPapTest exposing (main)

{-| `(==)` bound to a variable and partially applied to a `Float` works as a
predicate for `List.filter`.

`eq` is `(==)` itself, and `List.filter (eq 1.5)` keeps the two `1.5` elements
of `[1.0, 1.5, 2.0, 1.5]`.

## eco

`Float` uses an `f64` ABI, but a kernel partial application must take every argument boxed: the PAP of `Elm_Kernel_Utils_equal` must use the all-`!eco.value` ABI, not the `Float` one.

-}

-- CHECK: filtered: [1.5,1.5]

import Html exposing (text)


main =
    let
        eq = (==)
        filtered = List.filter (eq 1.5) [1.0, 1.5, 2.0, 1.5]
        _ = Debug.log "filtered" filtered
    in
    text "done"
