module CompilerIssue2362NanTupleEqualityTest exposing (main)

{-| (==) on a structure containing NaN depends on whether both sides are the same JS object.

<https://github.com/elm/compiler/issues/2362>

NaN is not equal to itself, so `(0/0, 1) == (0/0, 1)` is False, and comparing a tuple holding NaN
with itself must be False too. Elm 0.19.1 returns True for `p == p` because `_Utils_eq` first
checks `x === y` (the same object), and False for an equal tuple built separately.

-}

-- CHECK: nan == nan: False
-- CHECK: p == q: False
-- CHECK: p == p: False

import Html exposing (text)


main =
    let
        nan =
            0 / 0

        p =
            ( nan, 1 )

        q =
            ( 0 / 0, 1 )

        _ =
            Debug.log "nan == nan" (nan == nan)

        _ =
            Debug.log "p == q" (p == q)

        _ =
            Debug.log "p == p" (p == p)
    in
    text "done"
